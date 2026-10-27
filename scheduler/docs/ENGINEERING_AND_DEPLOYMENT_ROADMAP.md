# Software Engineering and Deployment Roadmap

This guide uses the scheduler application as a practical way to learn software
engineering, system design, DevOps, and production operations. It describes a
safe progression from local development to a cloud deployment without assuming
that every project needs Kubernetes, Redis, or a new database.

## 1. What this application is

The application has three main parts:

```text
User's browser
  └── React frontend
        └── Express API
              └── ERPNext REST API
                    └── ERPNext database and manufacturing documents
```

- **React frontend:** production scheduler and Sales Forecast views.
- **Node.js/Express backend:** serves application API routes, performs
  scheduling-related work, and holds ERPNext API credentials.
- **ERPNext:** source of truth for Work Orders, Job Cards, Sales Orders,
  Workstations, and related manufacturing data.
- **Local runtime state:** Work Order timer information is currently saved in
  `wo-timers.json`; some workstation information is held in backend memory.

The frontend must call the application backend. It must never call ERPNext
directly with a privileged API key or secret. ERPNext credentials belong only
on the backend.

## 2. Engineering qualities to learn

Software engineering is not only writing features. For each feature, practise
the complete cycle:

1. **Understand the problem:** write down the user, current behavior, desired
   behavior, and important failure cases.
2. **Trace the data flow:** identify the browser action, API request, backend
   handler, ERPNext request, and UI update.
3. **Choose a design:** compare options and record their costs, risks, and
   operational impact.
4. **Implement a small change:** keep the diff focused and preserve existing
   contracts unless a deliberate versioned change is planned.
5. **Verify it:** use automated tests, API checks, and a manual user flow.
6. **Operate it:** inspect metrics and logs, understand failure behavior, and
   know how to roll back.
7. **Explain it:** be able to describe what changed and why without relying on
   the code generator's explanation.

This routine builds practical interview skills: debugging, API design, data
modeling, testing, reliability, security, performance analysis, and technical
communication.

## 3. Current-state observations

These are observations about the codebase, not a claim that every item is a
production incident:

- `/api/schedule` obtains Work Order and Job Card documents, including child
  table data used for workstation placement and Job Card scheduling times.
  A live measurement during development returned 120 Work Orders, 246 Job
  Cards, and 385 ERPNext requests in about 2.85 seconds. That is a baseline
  from one measurement, not an SLA.
- ERPNext's current list API did not expose the child-table fields needed to
  replace those reads safely. Do not remove them just to lower a request
  counter. A purpose-built, permission-checked ERPNext method is a possible
  future improvement.
- `wo-timers.json` is local file state. It is not automatically shared between
  containers or servers, and its durability depends on a persistent volume and
  backups.
- An in-memory workstation map is local to one Node process. A restart loses
  it, and multiple backend replicas would each hold a different map.
- The README mentions SQLite caching, but the current backend should be
  inspected before relying on SQLite as an active datastore. A dependency
  being listed does not prove the application uses it.
- Health checking currently has a basic `/api/health` route. A production
  readiness check should also establish whether the backend can use its
  required ERPNext integration.
- Environment files are tracked in the repository at present. Before
  production deployment, ensure that no credentials or private values are
  committed. If a real secret was ever pushed to a remote, rotate it; deleting
  it from a later commit does not make the old value secret again.

## 4. Recommended engineering roadmap

### Phase 1 — Make development and changes repeatable

Learn Git and establish a reliable development baseline:

- Keep one branch that you have tested as the known-good integration branch.
- Create feature branches from that baseline; make small commits with one
  purpose each.
- Check `git status` before branch switches, merges, and commits.
- Keep local configuration out of commits. Frontend `REACT_APP_*` values are
  bundled into browser JavaScript and must be treated as public, even when
  sourced from a local `.env` file.
- Document how to run the backend, frontend, and ERPNext dependencies.
- Pin and test a supported Node.js LTS version in local development and CI.

**Practice exercise:** make a small UI-only change on a feature branch, test
it, merge it, and explain how you would undo the merge.

### Phase 2 — Establish correctness with tests

Before major optimization or deployment, create a regression safety net:

- Unit tests for pure transformations: Job Card time normalization, status
  mapping, schedule-event shaping, and forecast calculations.
- API tests for success, validation failure, ERPNext rejection, and network
  timeout cases.
- Mock ERPNext HTTP responses so tests are repeatable and do not create
  production documents.
- Frontend tests for tab navigation, loading/error states, and rendering
  schedule data.
- An end-to-end smoke test in a non-production ERPNext site for creating and
  rescheduling a test Work Order and its Job Cards.
- Test important response contracts. For example, `/api/schedule` should
  continue returning its expected keys and time fields.

Do not make automated tests write to the live ERPNext site. Use a dedicated
development or staging site and clearly separated API credentials.

### Phase 3 — Improve observability and diagnose performance

Measure before choosing a cache, queue, or scaling strategy:

- Record request duration, status code, route, and correlation/request ID.
- For ERPNext calls, measure duration and count by doctype/operation. Avoid
  logging credentials, authorization headers, customer data, or full
  manufacturing documents.
- Track schedule endpoint p50/p95 latency, ERPNext request count, failures,
  timeouts, and returned document counts.
- Separate application response time from the time spent waiting on ERPNext.
- Use repeated measurements under comparable load. A single before/after
  request can be noisy.
- Keep logs structured and configure rotation/retention.

The existing `[SCHEDULE]` logs are a useful learning baseline. The next useful
performance experiment is a staging-only ERPNext method that returns the
specific parent and child-table fields the dispatch board needs in bulk. Keep
the REST contract stable and compare results against the existing endpoint
before switching over.

### Phase 4 — Protect the API and ERPNext

Security and reliability work should precede public internet exposure:

- Create a dedicated ERPNext integration user with only the permissions the
  scheduler requires. Avoid using Administrator credentials.
- Store ERPNext API key and secret in the backend environment or a secret
  manager. Never put them in React environment variables, a Docker image, Git,
  screenshots, or logs.
- If credentials were committed or shared outside the trusted environment,
  revoke and rotate them.
- Restrict CORS to the deployed frontend origin. CORS is a browser policy, not
  API authentication.
- Add request validation and a reasonable JSON body-size limit.
- Add security headers (for example, Helmet) and rate limits for incoming
  application routes. Use stricter limits for expensive routes and
  document-creation routes.
- Consider the ERPNext API's own quotas and capacity when choosing limits.
  Rate limiting the scheduler protects ERPNext from bursts; it is not a
  substitute for authorization.
- Use timeouts for outbound calls. Retry only safe, idempotent reads, with
  bounded attempts and backoff. Blind retries of Work Order creation can
  create duplicates.
- Make write operations observable and return explicit failures; do not return
  success when ERPNext rejected a write.
- Use HTTPS and keep ERPNext private or reachable over a secured private
  network/VPN when possible.

### Phase 5 — Improve performance without changing behavior accidentally

Use this order:

1. Profile real requests and identify the largest sources of latency.
2. Request only fields that the UI actually uses.
3. Use supported bulk endpoints and pagination where the required fields are
   available.
4. Preserve child-table data and compare old/new API outputs before removing
   any document reads.
5. Bound concurrency so a single refresh does not overwhelm ERPNext.
6. Consider a short-lived cache for read-only schedule data only after
   measuring. Define expiry, invalidation after writes, and acceptable
   staleness first.
7. Re-measure with the same workload and compare both latency and correctness.

Caching is not automatically an improvement here. A stale schedule can cause
users to act on obsolete dates or statuses. A cache needs a clear freshness
policy and tests for updates, failed writes, and concurrent users. Do not add
Redis until measurements show a shared cache is necessary.

### Phase 6 — Make runtime state safe for restarts and multiple servers

Before running more than one backend instance:

- Move timer state from a local JSON file to a durable shared store, or
  deliberately make ERPNext the authoritative source if the timer model
  permits it.
- Persist or derive workstation mappings so they are not process-local.
- Define which service owns each piece of state and how updates are made
  atomic.
- Ensure duplicate API requests cannot create duplicate orders. Consider
  idempotency keys for create operations if clients may retry.
- Test server restarts during writes and simultaneous schedule changes.

If a database is introduced, plan schema migrations, backups, restore tests,
connection limits, and ownership. A database is not justified just because
other applications have one.

## 5. Deployment progression

### Stage A — Local development

- Run React and Express locally.
- Connect only to a development ERPNext site.
- Use ignored local environment files; keep example files free of real
  credentials.
- Confirm health checks, logs, and a basic schedule read.

### Stage B — Docker Compose on one Linux host

This is a good first container deployment and a useful learning step:

- Build the React app as static files and serve them with Nginx.
- Run Express in a separate Node container.
- Put Nginx or another reverse proxy in front to route `/api` to Express and
  browser routes to React.
- Use HTTPS (for example, a managed certificate or Let's Encrypt).
- Store secrets outside the image and repository.
- Add health checks, restart policy, log limits, and a persistent volume only
  for runtime data that must survive container replacement.
- Restrict inbound firewall rules to HTTPS and administrative access. Do not
  expose the Node port directly if the reverse proxy can reach it privately.

Compose is appropriate for a single machine, a demo, or a small internal
deployment. It is not a multi-host orchestrator and does not itself provide
high availability.

### Stage C — Managed cloud deployment

For a small AWS deployment, a reasonable next step is:

```text
Browser
  └── HTTPS: Route 53 + ACM + Application Load Balancer
        ├── Static React build: S3 + CloudFront (or Nginx container)
        └── Express API: ECS Fargate service
              ├── secrets: AWS Secrets Manager / Parameter Store
              ├── logs and alarms: CloudWatch
              └── private network path to ERPNext
```

Key decisions:

- If ERPNext is on a company network, arrange private connectivity such as a
  site-to-site VPN or another approved secure connection. Avoid exposing
  ERPNext's API publicly solely to make the scheduler reachable.
- Keep application containers in private subnets where possible; expose only
  the load balancer.
- Use least-privilege IAM roles for the service and deployment pipeline.
- Set CPU/memory, task count, health checks, deployment rollback, and log
  retention deliberately.
- Static hosting can be separated from the API; keep the frontend API URL
  pointed at the HTTPS application domain.
- Estimate and monitor cloud cost. A managed service reduces operations work
  but is not automatically cheaper.

Other providers offer equivalent building blocks. Select based on where
ERPNext already runs, network access, support, cost, and your organization's
skills. A simpler Linux VM from a cloud provider can be a valid learning
deployment before managed services.

### Stage D — Kubernetes only when it solves a real problem

Kubernetes (often abbreviated **K8s**) manages containerized applications
across a cluster. It can help when an organization already operates a cluster
or needs multiple services, advanced rollout strategies, autoscaling, and
platform-wide policy.

It also adds cluster upgrades, networking, ingress, storage, secrets,
observability, access control, and incident-response work. For this scheduler,
start with Compose or a managed container service such as ECS Fargate. Move to
Kubernetes only when there is a concrete requirement, such as an existing
company platform or several independently deployed services that benefit from
it—not simply to make the project appear production-grade.

## 6. A safe release process

Use the same sequence for every release:

1. **Plan:** define expected behavior, risk, and rollback.
2. **Branch:** start from the tested integration branch.
3. **Develop:** keep changes small and add regression tests.
4. **Local validation:** lint/build, unit/API tests, and manual happy-path
   checks.
5. **CI:** on pull request, install from lockfiles, run tests, build the
   frontend/backend artifacts, and scan dependencies/secrets.
6. **Review:** inspect the diff, verify no `.env`, credentials, generated
   output, or unrelated files are included.
7. **Staging:** deploy the same artifact to a staging environment connected to
   a non-production ERPNext site; run smoke tests.
8. **Production:** deploy a versioned immutable image/artifact, monitor health
   and error rates, and avoid mixing code changes with manual server edits.
9. **Rollback:** keep the prior artifact available and document how to restore
   it. For database changes, ensure migrations are backward compatible or have
   a tested recovery plan.
10. **Learn:** review incidents and record what to improve next time.

A simple CI pipeline should initially build and test. Add automated deployment
only after environment separation, secrets handling, approvals, and rollback
are clear.

## 7. Operational checklist

Before real users rely on the deployment, verify:

- [ ] HTTPS works and HTTP redirects to HTTPS.
- [ ] No ERPNext secret appears in frontend bundles, Git, logs, or container
      image layers.
- [ ] `.env` files with credentials are not tracked; exposed credentials have
      been rotated.
- [ ] CORS, authentication/authorization, and API permissions are configured.
- [ ] Health and readiness checks behave correctly.
- [ ] Logs do not expose private data and have retention/rotation.
- [ ] ERPNext timeouts and failure states are visible to users.
- [ ] Work Order and Job Card creation/reschedule flows have regression tests.
- [ ] Timer and mapping state survive the failure/restart scenarios the
      application promises to support.
- [ ] Backups and restore procedures are tested for every stateful store.
- [ ] Alerts exist for repeated failures, high latency, and unavailable
      dependencies.
- [ ] A rollback to the previous application version has been tested.

## 8. Suggested learning order

For this project, learn and implement in this order:

1. Git workflow and repeatable local setup.
2. HTTP/API fundamentals and request tracing.
3. Tests for schedule transformation and Work Order writes.
4. Logs, metrics, and performance profiling.
5. Input validation, least privilege, secret hygiene, and rate limiting.
6. Docker images and Docker Compose on Linux.
7. CI build/test pipeline.
8. HTTPS, reverse proxy, backups, monitoring, and incident practice.
9. Cloud networking and a managed container deployment.
10. Shared state and multiple backend replicas, if actual demand requires
    them.
11. Kubernetes only if the deployment's scale or platform needs justify it.

For each step, write down the problem, design options, tradeoffs, verification
results, and rollback plan. That record is useful both as project
documentation and as evidence of engineering judgment.
