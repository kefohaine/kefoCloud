.RECIPEPREFIX = >
.SHELLFLAGS := -eu -c

REPO := /var/www/github/jehpok.com/repo
COMPOSE := docker compose -f

.PHONY: up-domain up-cloud up-tailnet up-all
.PHONY: restart-domain restart-cloud restart-tailnet
.PHONY: logs-domain logs-cloud logs-tailnet
.PHONY: status push backup clean

up-domain:
>$(COMPOSE) $(REPO)/services/domain/docker-compose.yml up -d --force-recreate

up-cloud:
>$(COMPOSE) $(REPO)/services/cloud/docker-compose.yml up -d --force-recreate

up-tailnet:
>$(COMPOSE) $(REPO)/services/tailnet/docker-compose.yml up -d --force-recreate

up-all: up-tailnet up-domain up-cloud

restart-domain:
>$(COMPOSE) $(REPO)/services/domain/docker-compose.yml restart domain

restart-cloud:
>$(COMPOSE) $(REPO)/services/cloud/docker-compose.yml restart cloud

restart-tailnet:
>$(COMPOSE) $(REPO)/services/tailnet/docker-compose.yml restart tailnet

logs-domain:
>docker logs domain --tail 50 -f

logs-cloud:
>docker logs cloud --tail 50 -f

logs-tailnet:
>docker logs tailnet --tail 50 -f

status:
>docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

push:
>cd $(REPO) && git add -A && git commit -m "$(MSG)" && git push jehpok.com main

backup:
>docker exec -w /var/www/html cloud php occ maintenance:mode --on
>cp -a /var/www/github/jehpok.com/cloud/data /var/www/github/jehpok.com/cloud-backup-$$(date +%Y%m%d)
>docker exec -w /var/www/html cloud php occ maintenance:mode --off
>@echo "Backup at /var/www/github/jehpok.com/cloud-backup-$$(date +%Y%m%d)"

clean:
>docker builder prune -af
>sudo apt-get clean