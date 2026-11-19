.PHONY: up down status seal lint

up:            ## Create the kind cluster and bootstrap Argo CD (everything else comes from Git)
	./bootstrap/up.sh

down:          ## Delete the cluster (the Sealed Secrets key backup is kept)
	kind delete cluster --name gitops-demo

status:        ## Argo CD applications and app pods per environment
	kubectl -n argocd get applications
	@for ns in dev staging prod; do echo "--- $$ns"; kubectl -n $$ns get pods 2>/dev/null; done

seal:          ## (Re)generate the per-environment DB SealedSecrets: make seal ENV=dev
	./scripts/seal-db-secret.sh $(ENV)

lint:          ## Lint and render the chart for every environment
	helm lint charts/gitops-demo-app
	@for env in dev staging prod; do helm template t charts/gitops-demo-app -f envs/$$env/values.yaml >/dev/null && echo "render ok: $$env"; done
