.PHONY: up down test logs

# Fresh clone, no .env needed: build, bring the stack up, wait for
# everything (migrate/seed to finish, portal/notifier to be healthy).
up:
	docker compose up -d --build --wait
	@echo ""
	@echo "portal:  http://127.0.0.1:8080"
	@echo ""
	@echo "  curl -s http://127.0.0.1:8080/healthz"
	@echo "  curl -s -H 'Authorization: Bearer local-dev-token' http://127.0.0.1:8080/api/summary" # gitleaks:allow — fixed local-only dev token, not a secret
	@echo ""
	@echo "(local-dev-token is a fixed, local-only dev token — see docker-compose.yml)"

down:
	docker compose down

logs:
	docker compose logs -f

test:
	./scripts/test.sh
