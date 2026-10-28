# wizard.d/tasks/09-dns.sh — `DNS Records`: Cloudflare A/MX/SPF/DKIM/DMARC and the zone SSL mode.

# DNS Records: Cloudflare A/MX/SPF/DKIM/DMARC + SSL mode.
task_dns() {
  task_start
  cf_dns
  cred_note cloudflare "$CF_API_TOKEN"
  task_end
}
