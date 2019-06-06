# Exim Quota Daemon

This program can enfoce quota limits on RCPT time for exim.

This is a simple daemon that interacts with exim using the readsocket interface.
It only supports one command: check_quota <email address> <sender address> and will
return "0" or "1" depending if the defined quota was exceeded or not.
If first time exceeded it will send an email to <email address> to inform that the quota
is exceed and mail is rejected.
 
To save on IO it will cache the result using memcached.

It has a whitelist REGEX if you want to allow certain senders to bypass quota limits. For
example your helpdesk might still want to exchange email with the users.

You need a local memcached (debian default config works).
You need to install dalli ruby-gem (gem install dalli).

Open the file and edit the constants in the top section, create the directoryies and the quota file.
Then run this as a user that has read permissions to EMAIL_DIRECTORY and full access to the DIRECTORY.

## QUOTA_DIRECTORY
If you host multiple domains you can define quota per domain
The QUOTA_DIRECTORY is one file that looks like:
```
domaina.com:5000
domainb.org:1000
```

Size is in MB, so this would limit each mailbox in domaina.com to 5GB while mailboxes in domainb.org are limited to 1GB.

## Exim config

Add somewhere in the top section of exim.conf :

 ```
 OVERQUOTA_CHECK = ${readsocket{inet:localhost:2626}{CHECK_QUOTA $local_part@$domain $sender_address}{15s}{}{0}}
 ```

Then add to the acl "acl_check_rcpt"
```
  defer domains         = +local_domains
        condition       = ${if eq{OVERQUOTA_CHECK}{1} {yes}{no}}
        message         = The mailbox for $local_part@$domain is full, deferring.
        log_message     = Recipient mailbox is full, deferring.
```
This will temporarily deny the message, if you want to give a permanent error replace defer with deny.

## Testing

You can run exim-quotad with -d, this will listen on another port and output logs on STDOUT.
Then run
```
  telnet localhost 2627  
```
Then Type

```
check_quota a.user@mydomain-xyz.abc sender@address.com
```

## Credits

Martin Boese <mboese@mailbox.org>

Based on:
https://github.com/Exim/exim/wiki/Checking-quota-at-RCPT-time
