# Value vs Research Desk

A value screen of the S&P/ASX 200 and S&P 500, run against published research: broker consensus and
targets, dated rating changes, broker headlines, Substack write-ups and X. Public data only. Not investment advice.

- `build.pl` fetches everything and writes `dist/index.html` + `dist/data.json` (perl + curl, no other dependencies).
- `template.html` is the page. `substacks.json` is the list of Substack publications scanned each run: add or remove lines freely.
- `.github/workflows/refresh.yml` rebuilds and deploys to GitHub Pages every weekday morning (Sydney) and on **Run workflow**.

## Set up
1. Create the repository on GitHub and push this folder to `main`.
2. Settings > Pages > Source: **GitHub Actions**.
3. Actions > Refresh dashboard > **Run workflow**.

## Optional: X posts
X has no free read API. Without a token each stock gets an X search link. To pull posts into the page, buy
API access at developer.x.com and add the bearer token as the repository secret `X_BEARER_TOKEN`
(Settings > Secrets and variables > Actions). This path has not been tested with a live token.

## Local preview
`perl build.pl --limit 25` (quick) or `perl build.pl` (full, about 10 minutes), then open `dist/index.html`.
