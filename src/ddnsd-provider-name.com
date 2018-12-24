<?php
namespace KS\Ddnsd;

require __DIR__."/../vendor/autoload.php";



// Open syslog
openlog("ddnsd-providers-name.com", LOG_PID | LOG_PERROR, LOG_DAEMON);




// Handle incoming options
$cmd = new \Commando\Command();

$cmd->option()
    ->require()
    ->describedAs("The command to run")
    ->must(function($str) {
        return $str === 'change-ip';
    });

$cmd->option()
    ->require()
    ->describedAs("A JSON-formatted config object for the command");



// Config

$config = json_decode($cmd[1], true);
if (!$config) {
    syslog(LOG_ERR, "Config object must be valid json!");
    exit(2);
}

// Merge incoming config into defaults
$config = array_replace_recursive([
    "dev-mode" => false,
    "ttl" => 180,
], $config);




// Check for config errors

$err = null;

// IP
if (!array_key_exists('ip', $config) || !$config['ip']) {
    $err = "E: You must send the new ip address in your config object with key `ip`";

// domain
} elseif (!array_key_exists('domain', $config) || !$config['domain']) {
    $err = "E: You must send the domain in your config object with key `domain`";

// subdomains
} elseif (
    !array_key_exists('subdomains', $config) ||
    !$config['subdomains'] ||
    !is_array($config['subdomains']) ||
    count($config['subdomains']) === 0
) {
    $err = "E: You must send an array of subdomains in your config object with key `subdomains`";

// Dev mode
} elseif (!is_bool($config['dev-mode'])) {
    $err = "E: Config key `dev-mode` should be a boolean value.";

// Dev-mode-specific config
} elseif ($config['dev-mode']) {
    if (!array_key_exists('test-credentials', $config)) {
        $err = "E: You've indicated you're in dev mode, but haven't supplied test credentials. (`test-credentials` key)";
    }
}


// If config error, exit
if ($err) {
    syslog(LOG_ERR, $err);
    exit(12);
}


// Start API client options
$clientOpts = [
    'base_uri' => $config['dev-mode'] ? "https://api.dev.name.com" : "https://api.name.com",
    'headers' => [],
];


// Handle credentials

if ($config['dev-mode']) {
    $creds = $config['test-credentials'];
} else {
    $creds = getenv("DDNSD_CREDENTIALS");
}

if (!$creds) {
    syslog(
        LOG_ERR,
        "Credentials not found! Credentials should either be supplied via the DDNSD_CREDENTIALS environment ".
        "variable or or using the `test-credentials` key in the config array. Exiting."
    );
    exit(6);
}

$creds = explode(":", $creds);
$credProtocol = array_shift($creds);
$creds = implode(":", $creds);

if ($credProtocol === "HTTPAUTH") {
    $creds = str_replace("|", ":", $creds);
    syslog(
        LOG_DEBUG,
        "Final credentials before encoding: $creds"
    );
    $clientOpts['headers']['Authorization'] = "Basic ".base64_encode($creds);
} else {
    syslog(LOG_ERR, "Don't know how to handle credential protocol `$credProtocol`! Exiting.");
    exit(8);
}



// Create API Client
$client = new \GuzzleHttp\Client($clientOpts);


$returnCode = 0;


// Get list of current DNS Records
try {
    syslog(
        LOG_INFO,
        "Getting DNS records from endpoint /v4/domains/$config[domain]/records"
    );
    $dns = $client->get("/v4/domains/$config[domain]/records");
    $dns = json_decode((string)$dns->getBody(), true);


    // Iterate through subdomains and change IPs, if necessary
    foreach($config['subdomains'] as $subdomain) {
        syslog(LOG_DEBUG, "Processing `$subdomain.$config[domain]`");

        // See if we can find this entry in the current records
        $entry = null;
        foreach ($dns['records'] as $record) {
            if (!array_key_exists('host', $record)) {
                if ($subdomain === '@') {
                    $entry = $record;
                    break;
                }
            } elseif ($record['host'] === $subdomain) {
                $entry = $record;
                break;
            }
        }

        $done = false;
        $attempts = 0;
        while(!$done && $attempts < 3) {
            try {
                // If this subdomain is already registered...
                if ($entry) {
                    // And the IP has changed.... Update.
                    if ($entry['answer'] !== $config['ip']) {
                        $entry['answer'] = $config['ip'];
                        $entry['ttl'] = $config['ttl'];
                        $client->put("/v4/domains/$config[domain]/records/$entry[id]", [ 'json' => $entry ]);
                        syslog(LOG_DEBUG, "Successfully updated record for '$subdomain.$config[domain]', pointing to $config[ip]");
                        $done = true;
                    } else {
                        $done = true;
                    }

                    // Otherwise, add a new record
                } else {
                    $entry = [
                        "host" => $subdomain,
                        "answer" => $config['ip'],
                        "ttl" => $config['ttl'],
                        "type" => "A",
                    ];
                        $client->post("/v4/domains/$config[domain]/records", [ 'json' => $entry ]);
                        syslog(LOG_DEBUG, "Successfully created record for '$subdomain.$config[domain]', pointing to $config[ip]");
                        $done = true;
                }
            } catch (\GuzzleHttp\Exception\ServerException $e) {
                syslog(LOG_WARNING, "W: Server returned an error: {$e->getMessage()}. Waiting 5 seconds to try again....");
                $attempts++;
                sleep(5);
            }
        }

        if (!$done) {
            syslog(LOG_ERR, "E: Couldn't complete the requested action for '$subdomain.$config[domain]'!");
            $returnCode = 14;
        }
    }
} catch (\GuzzleHttp\Exception\ClientException $e) {
    syslog(LOG_ERR, $e->getMessage());
    $returnCode = 16;
}





// Close up logs

closelog();

exit($returnCode);

