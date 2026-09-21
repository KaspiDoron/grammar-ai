# Putting the landing page on your own domain

The landing page is already live at
**https://kaspidoron.github.io/grammar-ai/** - that URL works today, for free,
with HTTPS. Everything below is only to serve it from a custom domain like
`typfix.com`.

Two things are needed that only you can do, because they need your money and
your accounts: buying the domain, and adding DNS records at the registrar. I
cannot do those for you. Once they are done, `scripts/set-custom-domain.sh`
wires up the repo side in one command.

## Step 1 - Buy the domain

- `typfix.com` was available when this was written. Good registrars: Cloudflare
  Registrar (at-cost, recommended), Namecheap, Porkbun.
- `typfix.app` may or may not be available - check at your registrar. Note that
  `.app` is HTTPS-only, which GitHub Pages handles automatically, so it works
  fine.

## Step 2 - Add DNS records at the registrar

In your registrar's DNS settings for the domain, add these records.

For an apex domain (`typfix.com`), add four A records and one AAAA set:

- Type `A`, Name `@`, Value `185.199.108.153`
- Type `A`, Name `@`, Value `185.199.109.153`
- Type `A`, Name `@`, Value `185.199.110.153`
- Type `A`, Name `@`, Value `185.199.111.153`
- Type `AAAA`, Name `@`, Value `2606:50c0:8000::153`
- Type `AAAA`, Name `@`, Value `2606:50c0:8001::153`
- Type `AAAA`, Name `@`, Value `2606:50c0:8002::153`
- Type `AAAA`, Name `@`, Value `2606:50c0:8003::153`

And a CNAME so `www` works too:

- Type `CNAME`, Name `www`, Value `kaspidoron.github.io`

(If you prefer to use only `www.typfix.com`, you can skip the A/AAAA records
and just add the `www` CNAME, then set the custom domain to `www.typfix.com`
in Step 3.)

These are GitHub's official Pages IP addresses. They rarely change; if HTTPS
ever fails, re-check them at
https://docs.github.com/pages/configuring-a-custom-domain-for-your-github-pages-site

## Step 3 - Wire up the repo (one command)

```bash
scripts/set-custom-domain.sh typfix.com
```

This writes `site/CNAME`, sets the domain in the repo's Pages settings, and
pushes. Then, in the repo on GitHub, go to Settings > Pages and tick "Enforce
HTTPS" once the certificate has been issued (it can take up to an hour).

## Step 4 - Verify

After DNS propagates (minutes to a few hours):

```bash
curl -sI https://typfix.com | head -1     # expect: HTTP/2 200
```

Then update the links: search the repo for `kaspidoron.github.io/grammar-ai`
and the README/landing "GitHub" buttons if you want the site to advertise the
custom domain.
