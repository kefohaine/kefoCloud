# wizard.d/tasks/09-dns.sh — `DNS Records`: Cloudflare A (from the door exposure) / MX / SPF / DKIM / DMARC.

# DNS Records: Cloudflare A records from the recorded exposure, plus MX/SPF/DKIM/DMARC.
task_dns() {
  task_start
  cf_dns
  cred_note cloudflare "$CF_API_TOKEN"
  task_end
}
