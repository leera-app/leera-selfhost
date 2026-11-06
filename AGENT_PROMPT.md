Install Leera (self-hosted) for me, end to end.

Work through these phases in order. Stop and wait for me before anything that
costs money or changes DNS.

PHASE 1: Ask me where it should run
Ask which of these I want, and do nothing else until I answer:
  (a) AWS: you create the EC2 instance and the Route 53 record
  (b) GCP: you create the Compute Engine VM and the Cloud DNS record
  (c) A server I already have: I give you the host and SSH user
  (d) This machine: local evaluation only, no domain, plain HTTP

PHASE 2: Get access, without me pasting secrets
Never ask me to type a password, private key, or access key into this chat.
Check what you already have:
  AWS: aws sts get-caller-identity
  GCP: gcloud auth list ; gcloud config get-value project
  SSH: ssh -o BatchMode=yes <user>@<host> true
If a check fails, stop and tell me the exact command to run in my own terminal
(aws configure sso, gcloud auth login, ssh-add ~/.ssh/<key>), then wait for me.
Then ask for the region/project/zone, and the domain I want to use, for
example pm.example.com. Confirm I actually control that domain's DNS.

PHASE 3: Show me a priced plan before you build anything
List what you will create and the rough monthly cost, then wait for a yes:
  - one Linux VM: 2 vCPU, 4 GB RAM, 25 GB disk, current Ubuntu LTS
    (AWS t3.medium or GCP e2-medium is the right size to start)
  - a firewall rule opening ONLY 22, 80 and 443
  - a static IP, so the address survives a reboot
  - one DNS A record for my domain pointing at that IP
Create nothing outside that list. Do not modify or delete existing VPCs,
instances, security groups or DNS records that you did not create. If the
sensible path needs an existing resource, name it and ask me first.

PHASE 4: Build it
Provision exactly what I approved, and tag every resource "leera-selfhost" so
it is easy to find and to tear down later. Report the resource IDs as you go.

PHASE 5: Wait for DNS before installing. This one matters.
The installer requests an HTTPS certificate on first start, and Let's Encrypt
fails if the domain does not already resolve to the server. Do not skip ahead.
Poll until `dig +short <domain>` returns the VM's IP from more than one
resolver, and only then continue. If it has not propagated within 10 minutes,
tell me. Do not install anyway and leave me with a broken certificate.

PHASE 6: Install
Ask whether I want to give the installer my email (it is used to register
my licence and to help if the install fails). If I do, add LEERA_EMAIL=<email>
to the command below; if not, leave it out. SSH to the server and run:
  LEERA_DOMAIN=<domain> LEERA_INSTALL_DOCKER=yes \
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/leera-app/leera-selfhost/main/install.sh)"
Docker does not need to be installed first; the installer handles it. This
pulls images and takes a few minutes.

PHASE 7: Prove it works. Do not just assert it.
  - cd ~/leera && ./install.sh --status
  - curl -sS -o /dev/null -w '%{http_code}' https://<domain>   → expect 200
  - curl -sSI https://<domain>                                 → no TLS error
If any of those fail, read the logs before reporting anything:
  cd ~/leera && docker compose logs --tail=100 caddy api web
Diagnose and fix it, or tell me plainly what is broken. Never report success
you have not verified.

PHASE 8: Hand it over
Tell me:
  - the URL, and that THE FIRST ACCOUNT CREATED BECOMES THE ADMINISTRATOR,
    so I should sign up immediately, before anyone else reaches it
  - that everything lives in ~/leera, including the .env holding my secrets
  - how to back up: cd ~/leera && ./install.sh --backup, and that a backup
    only counts once it is copied OFF the server
  - how to upgrade: cd ~/leera && ./install.sh --upgrade
  - every resource you created, so I can delete it if I change my mind

IF YOU HIT A PERMISSION WALL
Do not work around it, and do not quietly give up. Tell me:
  - what you tried, and the exact error
  - which specific IAM permission or role is missing
  - the fastest way for me to grant it: as a command I can paste, AND as
    click-by-click console steps, since I may not have CLI admin rights
  - or, if I would rather do that one step myself, exactly what to click
Then wait for me. A stalled install I can finish beats a half-built one.
