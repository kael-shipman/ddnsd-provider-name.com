#!/usr/bin/env php
<?php
namespace KS\Ddnsd;

require __DIR__."/../vendor/autoload.php";



// Open syslog
openlog("ddnsd-providers-name.com", LOG_PID | LOG_PERROR, LOG_DAEMON);







// Define functions
function getCSRF(string $html)
{
    if (!preg_match("/csrf-token['\"][a-zA-Z ='\"]+([a-fA-F0-9]{50,})/", $html, $csrf)) {
        syslog(LOG_ERR, "Couldn't find CSRF token :(. Exiting.");
        exit(4);
    } else {
        return $csrf[1];
    }
}

function getDnsEntry($records, $hostname)
{
    foreach ($records as $r) {
        if ($r['name'] === $hostname) {
            return $r;
        }
    }
    return null;
}






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

$config = json_decode($cmd[1], true);
if (!$config) {
    syslog(LOG_ERR, "Config object must be valid json!");
    exit(2);
} else {
    $err = null;
    if (!array_key_exists('ip', $config) || !$config['ip']) {
        $err = "E: You must send the new ip address in your config object with key `ip`";
    } elseif (!array_key_exists('domain', $config) || !$config['domain']) {
        $err = "E: You must send the domain in your config object with key `domain`";
    } elseif (!array_key_exists('subdomains', $config) || !$config['subdomains']) {
        $err = "E: You must send an array of subdomains in your config object with key `subdomains`";
    } elseif (!is_array($config['subdomains']) || count($config['subdomains']) === 0) {
        $err = "E: You must provide an array of subdomains in your config object with key `subdomains`";
    }

    if ($err) {
        syslog(LOG_ERR, $err);
        exit(12);
    }
}

$domain = $config['domain'];
$subdomains = $config['subdomains'];
$ip = $config['ip'];
$ttl = array_key_exists('ttl', $config) ? $config['ttl'] : 300;




// Handle credentials
$creds = getenv("DDNSD_CREDENTIALS");
if (!$creds) {
    syslog(LOG_ERR, "Credentials not found! Exiting.");
    exit(6);
}
$creds = explode(":", $creds);
$credProtocol = array_shift($creds);
$creds = implode(":", $creds);

if ($credProtocol !== "USERPASS") {
    syslog(LOG_ERR, "Don't know how to handle credential protocol `$credProtocol`! Exiting.");
    exit(8);
}

$creds = explode("|", $creds);
if (count($creds) > 2) {
    $u = array_shift($creds);
    $p = implode("|", $creds);
    $creds = [$u, $creds];
}

if (count($creds) !== 2) {
    syslog(LOG_ERR, "Hm... Looks like we're missing a username or password. Exiting.");
    exit(10);
}




// Log in and make changes

$browser = new \GuzzleHttp\Client([
    'base_uri' => "https://www.name.com",
    'cookies' => true,
    'allow_redirects' => true,
]);

$stdHeaders = [
    'DNT' => '1',
    'Host' => 'www.name.com',
    'User-Agent' => 'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:58.0) Gecko/20100101 Firefox/58.0',
];

// initialize
$r = $browser->request("GET", "/");
$csrf = getCSRF((string)$r->getBody());
syslog(LOG_INFO, "Initialized");

// login
$browser->request("POST", "/login", [
    'headers' => array_merge($stdHeaders, ['Accept' => 'application/json, text/javascript, */*; q=0.01',]),
    'form_params' => [
        'acct_name' => $creds[0],
        'csrf_token' => $csrf,
        'password' => $creds[1],
    ],
]);
syslog(LOG_INFO,  "Logged in");

// Get list of current DNS Records
$dns = $browser->request("GET", "/api/v3/domain/$domain/dns", [
    'headers' => array_merge($stdHeaders, ['x-csrf-token-auth' => $csrf,])
]);
$dns = json_decode((string)$dns->getBody(), true);
syslog(LOG_INFO, "Current listing");


// iterate through subdomains
foreach($subdomains as $subdomain) {
    if ($subdomain === '@') {
        $hostname = $domain;
    } else {
        $hostname = "$subdomain.$domain";
    }

    // If we can find the host in the dns records....
    $entry = getDnsEntry($dns, $hostname);
    if ($entry) {
        // Then if the ip has changed, update
        if ($entry['content'] !== $ip) {
            $entry['content'] = $ip;
            $entry['ttl'] = $ttl;
            $browser->request("PUT", "/api/v3/domain/$domain/dns", [
                'headers' => array_merge($stdHeaders, ['x-csrf-token-auth' => $csrf,]),
                'json' => $entry,
            ]);
        }

    // Otherwise, add records
    } else {
        $browser->request("POST", "/api/v3/domain/$domain/dns", [
            "headers" => array_merge($stdHeaders, ['x-csrf-token-auth' => $csrf,'Content-Type' => "application/json"]),
            "json" => [
                "content" => $ip,
                "created_date" => (new \DateTime("now", new \DateTimeZone('UTC')))->format(\DateTime::RFC3339_EXTENDED),
                "model_name" => "dns",
                "name" => $hostname,
                "prio" => null,
                "ttl" => $ttl,
                "type" => "A",
            ],
        ]);
    }
}





// Close up logs

closelog();

