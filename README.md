<p align="center">
  <img src="https://raw.githubusercontent.com/heddlehq/Bobbin/main/assets/img/logo.png" alt="Bobbin" width="180" />
</p>

<h2 align="center">Bobbin</h2>

<p align="center">
  <em>The SDK for building custom integrations and extensions for Heddle.</em>
</p>

<p align="center">
  <a href="https://hex.pm/packages/bobbin"><img src="https://img.shields.io/hexpm/v/bobbin?style=flat-square&color=6e4a7e&label=hex.pm" alt="Hex.pm" /></a>&nbsp;
  <a href="https://hexdocs.pm/bobbin"><img src="https://img.shields.io/badge/docs-hexdocs-8b5cf6?style=flat-square&logo=elixir&logoColor=white" alt="Docs" /></a>&nbsp;
  <a href="https://github.com/heddlehq/Bobbin/blob/main/LICENSE"><img src="https://img.shields.io/github/license/heddlehq/Bobbin?style=flat-square&color=blue" alt="License" /></a>&nbsp;
  <a href="https://github.com/heddlehq/Bobbin"><img src="https://img.shields.io/github/stars/heddlehq/Bobbin?style=flat-square&color=f5a623&logo=github" alt="GitHub Stars" /></a>&nbsp;
  <a href="https://discord.gg/7zjnpna239"><img src="https://img.shields.io/discord/1474594465225117740?style=flat-square&color=5865F2&logo=discord&logoColor=white&label=community" alt="Discord" /></a>
</p>

---

> [!IMPORTANT]
> **Status:** This project is currently in active development.

**Bobbin** is an Elixir SDK for building custom integrations and extensions for **Heddle**. It provides the tools to simplify the development of nodes and real-time workflows.

## 🚀 Getting Started

Add `bobbin` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bobbin, "~> 0.3"}
  ]
end
```

For detailed documentation, visit **[HexDocs](https://hexdocs.pm/bobbin)**.

## Integrations without code

Most integrations are a set of HTTP calls. Write them as a YAML manifest and each
action becomes a node in Heddle, with a `success` and an `error` output:

```bash
mix bobbin.new acme_crm                     # writes acme_crm.yaml to fill in
mix bobbin.validate acme_crm.yaml           # says what is wrong, if anything
mix bobbin.run acme_crm.yaml "Get Item" \
  --field id=42 --credential api_key=$KEY   # runs an action against the real API
```

```yaml
id: acme_crm
name: Acme CRM
version: 1.0.0
base_url: https://api.acme.test/v1/

credential:
  fields:
    - {name: api_key, label: API key, secret: true}
  auth: {type: bearer, token: "{{credential.api_key}}"}

actions:
  - name: Get Item
    fields:
      - {name: id, label: Item ID}
    request: {method: GET, path: "items/{{fields.id}}"}
    output: {pick: [id, name]}
```

Requests are built with `{{fields.<name>}}` and `{{credential.<name>}}`, empty values
are left out, and pagination comes in three presets: `cursor`, `offset` and `link`.
See `Bobbin.Integration` for the whole format, and
[`priv/integration.schema.json`](priv/integration.schema.json) for editors that read
JSON Schema.

For what a manifest can't express, write a node in Elixir with `Bobbin.Node`.

## 🤝 Community & Contributing

We believe in building in public. Join our community to discuss ideas, track our vision, or help us build:

- **Discord**: Join our [Discord Server](https://discord.gg/7zjnpna239) for support.
- **GitHub**: Contribute via [GitHub Issues](https://github.com/heddlehq/Bobbin/issues).

## License

Bobbin is open-source software licensed under the [MIT license](LICENSE).
