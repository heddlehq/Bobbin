# Writing a manifest

An integration without code is one YAML file. Heddle reads it and makes a node for
each action, which sends an HTTP request to the service and answers through its
`success` or `error` output.

You can write one in Heddle's **Integrations** page, under **Create integration**, or
in a file, checking it with the Mix tasks:

```bash
mix bobbin.new my_service                   # writes my_service.yaml to fill in
mix bobbin.validate my_service.yaml         # says what is wrong, if anything
mix bobbin.run my_service.yaml "Get Item" \
  --field id=42 --credential api_key=$KEY   # runs an action against the real API
```

When the service publishes an OpenAPI 3 spec, start from a draft of it instead:

```bash
mix bobbin.import https://api.acme.test/openapi.json --id acme --tag contacts,deals
```

Each operation becomes an action and each parameter or body property a field, with
its type. Give the actions the names people look for, keep the ones worth a node, and
add `output` and `pagination`.

YAML anchors and aliases (`&name`, `*name`) aren't supported: the YAML reader Bobbin
uses turns an alias of a map into its first key. Write a repeated field out each time.

## The service

```yaml
id: my_service
name: My Service
version: 1.0.0
description: What My Service does, in one line.
icon: hero-puzzle-piece
logo: |
  <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="#4F46E5" d="..."/></svg>
base_url: https://api.example.com/v1/
```

| Key | What it is |
| --- | --- |
| `id` | Lowercase letters, digits and `_`. It can't change once installed. |
| `name` | What the sidebar shows. Nodes are called "Name: Action". |
| `version` | Like `1.0.0`. Raise it when you change the manifest. |
| `icon` | A [heroicon](https://heroicons.com), like `hero-envelope` or `hero-cube-solid`. Shown when there is no `logo`. |
| `logo` | The service's own logo: an SVG, written in the manifest, of at most 30 KB. No scripts, event handlers or `foreignObject`. With it, the nodes' icon is `logo-<id>`, the class the host shows the logo under. |
| `base_url` | The start of every request's address. It may take values of the credential, see below. |
| `headers` | Headers of every request, like `{Intercom-Version: "2.11"}`. A request's own headers win. |

## An address per account

When each account has its own address, like `acme.zendesk.com`, or the service runs
on the user's own server, `base_url` takes it from the credential:

```yaml
base_url: "https://{{credential.subdomain}}.zendesk.com/api/v2/"
# or, for a server the user runs:
base_url: "{{credential.url}}/api/v4/"
```

A value inside the host may hold only letters, digits, `.` and `-`. A value at the
start must be a whole `http` or `https` address, with no user, query or fragment.
Anything else fails the request, so a credential can't send it somewhere else.

## Templates

Values in `{{ }}` are filled in when the node runs: `{{fields.x}}` is what the node's
field `x` holds, and `{{credential.x}}` a value of the credential. A string that is a
single placeholder keeps the value's type. A value that ends up empty is left out of
the query and the body, so optional fields need no extra syntax.

Templates work in `request`, `credential.auth` and `output.value`.

In `request.path` a value stays one segment: `/`, `?` and spaces are encoded, so
`group/app` goes as `group%2Fapp`. When it should span segments, like GitHub's
`owner/name`, write `{{fields.repo | path}}`.

## The credential

What a person fills in once, in Heddle's Credentials, and every node of the
integration uses. A field with `secret: true` is encrypted and never shown again.

A token in the `Authorization` header:

```yaml
credential:
  label: My Service
  fields:
    - name: api_key
      label: API key
      secret: true
  auth:
    type: bearer
    token: "{{credential.api_key}}"
```

A key in a header of its own:

```yaml
auth:
  type: header
  name: X-Api-Key
  value: "{{credential.api_key}}"
```

A user and a password:

```yaml
auth:
  type: basic
  username: "{{credential.username}}"
  password: "{{credential.password}}"
```

OAuth 2.0, with a Connect button. Heddle runs the authorization, renews the token and
passes it as `{{credential.access_token}}`:

```yaml
credential:
  label: My Service
  fields:
    - name: client_id
      label: Client ID
    - name: client_secret
      label: Client secret
      secret: true
  auth:
    type: oauth2
    authorize_url: https://example.com/oauth/authorize
    token_url: https://example.com/oauth/token
    scopes: [read, write]
```

The other types:

- `query`: the key goes in the address, with `name` and `value`.
- `none`: for public APIs. The integration then needs no credential.

### Tokens Bobbin fetches

OAuth 2.0 between servers, with no Connect button. Bobbin asks for a token with the
client ID and secret, keeps it until it expires and asks again when the service
refuses it. `token_auth: body` sends the ID and secret in the form instead of in the
`Authorization` header:

```yaml
auth:
  type: client_credentials
  token_url: https://example.com/oauth/token
  client_id: "{{credential.client_id}}"
  client_secret: "{{credential.client_secret}}"
  scopes: [read]
```

A login that trades a user and a password for a token. `token_path` is where the
answer holds it (`header:X-Token` for a header), `expires_path` or `expires_in`
(seconds, 600 when neither is there) how long it lasts. `apply` puts the token on
each request, as a bearer token when left out:

```yaml
auth:
  type: login
  request:
    method: POST
    path: auth/login          # or url: for another address
    body:
      username: "{{credential.username}}"
      password: "{{credential.password}}"
  token_path: data.token
  apply:
    type: header
    name: X-Session
    value: "{{auth.token}}"
```

### Signed requests

A JSON Web Token, signed for each request with `HS256`, `HS384`, `HS512` (a secret;
`key_encoding: hex` or `base64` when it is written that way), `RS256` or `ES256` (a
private key in PEM). `iat` and `exp` are added, `lifetime` seconds apart (300 when
left out):

```yaml
auth:
  type: jwt
  algorithm: HS256
  key: "{{credential.secret}}"
  key_encoding: hex
  header:
    kid: "{{credential.key_id}}"
  claims:
    aud: /admin/
  apply:
    type: header
    name: Authorization
    value: "Ghost {{auth.token}}"
```

An HMAC of each request. `message` may use `{{request.method}}`, `{{request.path}}`,
`{{request.query}}` (as sent), `{{request.body}}` (as sent), `{{request.timestamp}}`
(milliseconds) and `{{request.timestamp_s}}`. `params` are added to the address and
`headers` to the request before signing. The signature goes in a `header` or in the
`query`, in `hex` or `base64`:

```yaml
auth:
  type: hmac
  algorithm: sha256         # sha1, sha256 or sha512
  secret: "{{credential.secret}}"
  params:
    timestamp: "{{request.timestamp}}"
  headers:
    X-Api-Key: "{{credential.key}}"
  message: "{{request.query}}"
  signature:
    query: signature
```

AWS Signature Version 4:

```yaml
auth:
  type: aws_sigv4
  access_key_id: "{{credential.access_key_id}}"
  secret_access_key: "{{credential.secret_access_key}}"
  region: "{{credential.region}}"
  service: sqs
```

### Client certificates

Services that check who calls them by certificate, like the Brazilian banks' Pix
APIs, take one in the credential, next to `auth`. Both are PEM:

```yaml
credential:
  fields:
    - {name: certificate, label: Certificate (PEM), type: textarea}
    - {name: private_key, label: Private key (PEM), type: textarea, secret: true}
  tls:
    cert: "{{credential.certificate}}"
    key: "{{credential.private_key}}"
  auth:
    type: client_credentials
    ...
```

Bobbin also uses the certificate to ask for the token.

## Actions

Each action is a node. Its `fields` are what a person fills in the node, and its
`request` is what the node sends.

```yaml
actions:
  - name: Create Contact
    description: Creates a contact.
    fields:
      - name: email
        label: Email
        required: true
      - name: plan
        label: Plan
        type: select
        default: free
        options:
          - {label: Free, value: free}
          - {label: Pro, value: pro}
    request:
      method: POST
      path: contacts
      body:
        email: "{{fields.email}}"
        plan: "{{fields.plan}}"
```

| Key | What it is |
| --- | --- |
| `resource` | What the action works on, like `Contact` or `Deal`. Heddle groups actions by it. |
| `fields[].type` | `text` (the default), `textarea`, `number`, `select` or `multiselect` with `options`, `boolean`, `json`, `datetime` or `file`. |
| `fields[].required` | The action fails, saying so, when the field is empty. |
| `request.method` | `GET`, `POST`, `PUT`, `PATCH` or `DELETE`. |
| `request.path` | Joined to `base_url`. It may hold templates. |
| `request.query` | The parameters of the address, as a map. |
| `request.headers` | Headers of this request, besides the credential's. |
| `request.body_type` | `json`, the default, `form`, `multipart` or `binary`, see Files. |

A `select` sends its option's `value` as written, so `value: 2` goes as a number and
`value: "2"` as text. A `boolean` sends `true` or `false`. A `json` field sends what its JSON describes,
a map or a list, and fails when it isn't JSON. In `query`, a map goes as JSON text and a
list of plain values as `a,b,c`, or once per value when the key ends in `[]`
(`tags[]=a&tags[]=b`). A `multiselect` sends a list, and
takes one written as `a, b` too. A `datetime` sends the text as written, once it
reads as an ISO 8601 date (`2026-01-31` or `2026-01-31T09:00:00Z`). With `format: unix` or
`format: unix_ms`, it goes as seconds or milliseconds since 1970 instead, for APIs
that count time that way; a date without an offset is read as UTC. An empty field is
left out of the request.

A `_merge` key spreads a map, usually a `json` field, into the map that holds it, so
custom fields sit next to the fixed ones (its keys win):

```yaml
body:
  fields:
    summary: "{{fields.summary}}"
    _merge: "{{fields.custom_fields}}"   # {"customfield_10010": "x"}
```

Options can come from the service, so people pick a channel or a spreadsheet by name
instead of pasting its ID. `options_from` takes a `request`, the `path` of the items
in the answer, and the keys of each item that are its `label` and `value` (`name`
and `id` when left out). The request may use other fields, so a list can depend on
what was picked before:

```yaml
fields:
  - name: spreadsheet
    label: Spreadsheet
    type: select
    options_from:
      request: {method: GET, path: files, query: {q: "mimeType='sheet'"}}
      path: files
      label: name
      value: id
  - name: tab
    label: Tab
    type: select
    options_from:
      request: {method: GET, path: "spreadsheets/{{fields.spreadsheet}}"}
      path: sheets
      label: properties.title
      value: properties.title
```

Filters in the address:

```yaml
request:
  method: GET
  path: contacts
  query:
    email: "{{fields.email}}"
    limit: 50
```

## Files

A node that downloads a file keeps it and returns a reference to it,
`{"file": {"id", "name", "mime", "size"}}`, so a file never travels inside a run's
data. `output.file` does it, with the name from a template or, when left out, from
the answer's `Content-Disposition`:

```yaml
- name: Download File
  fields:
    - {name: id, label: File ID}
  request: {method: GET, path: "files/{{fields.id}}/content"}
  output:
    file:
      name: "{{fields.id}}.pdf"   # or file: true
```

A field of type `file` takes such a reference, usually `{{result}}` of the node that
downloaded it. Sent in a `multipart` body, it goes as a file with its name and type;
maps and lists in the same body go as JSON. A `binary` body is the file alone, with its
type as `Content-Type` unless the request sets one:

```yaml
- name: Upload File
  fields:
    - {name: file, label: File, type: file, required: true, default: "{{result}}"}
    - {name: folder, label: Folder ID}
  request:
    method: POST
    path: upload
    body_type: multipart
    body:
      file: "{{fields.file}}"
      metadata: {parent: "{{fields.folder}}"}
```

Heddle keeps files with the run and drops them when it expires. `mix bobbin.run`
keeps them in the system's temporary folder (see `Bobbin.Files`).

## Responses

The node leaves the body of the response in `result`. `output` keeps only what
matters, and an answer that isn't 2xx goes to the `error` output.

Part of the body, and some keys of each item:

```yaml
output:
  path: data.items
  pick: [id, name, email]
```

A value of your own, in place of the body:

```yaml
output:
  value:
    id: "{{fields.id}}"
    deleted: true
```

For APIs that answer 200 when something failed, `errors` names a field of the body
that must be `true`, and the one that says why. It goes at the top of the manifest and
counts for every action, like Slack's `{"ok": false}`:

```yaml
errors:
  ok_path: ok
  message_path: error
```

GraphQL answers 200 with the errors in `errors`. `error_path` names a field that
must be empty:

```yaml
errors:
  error_path: errors
  message_path: errors.0.message
```

## Pagination

With `pagination`, the node asks for every page and returns all the items together,
from `items_path`, or the whole answer when it's a list and `items_path` is left out.

A cursor the answer returns:

```yaml
pagination:
  type: cursor
  items_path: data
  cursor_param: cursor
  next_path: next_cursor
  page_size: 100
  limit_param: limit
```

An offset that grows:

```yaml
pagination:
  type: offset
  items_path: results
  offset_param: offset
  limit_param: limit
  page_size: 100
```

A page number, from 1 (`first_page` when it starts elsewhere):

```yaml
pagination:
  type: page
  items_path: results
  page_param: page
  limit_param: per_page
  page_size: 100
```

The `Link` header, like GitHub's:

```yaml
pagination:
  type: link
  page_size: 100
  limit_param: per_page
```

Or the next page's address in the answer, at `next_path`, like Twilio's
`next_page_uri`. It may be relative. Either way, Bobbin only follows an address on the
service's own host.

A cursor stops when `next_path` is empty, or when `has_more_path` says `false`.

Searches sent by POST, and GraphQL, take the page parameters in the body: with
`in: body`, `cursor_param`, `limit_param`, `offset_param` and `page_param` are paths
in the JSON body:

```yaml
request:
  method: POST
  path: graphql
  body:
    query: "query($first: Int, $after: String) { issues(first: $first, after: $after) { nodes { id title } pageInfo { hasNextPage endCursor } } }"
pagination:
  type: cursor
  in: body
  items_path: data.issues.nodes
  limit_param: variables.first
  cursor_param: variables.after
  next_path: data.issues.pageInfo.endCursor
  has_more_path: data.issues.pageInfo.hasNextPage
  page_size: 50
```

## Triggers

A trigger starts a flow when something new shows up in the service. It's written like
an action whose output is a list, plus `poll`. Heddle calls its request every few
minutes and starts the flow once for each item it hasn't seen.

```yaml
triggers:
  - name: New Item
    description: Starts the flow for each new item.
    request:
      method: GET
      path: items
      query:
        sort: created_desc
    output:
      path: items
    poll:
      every: 5   # minutes, 5 when left out
      id: id     # the key that tells items apart, "id" when left out
```

The first call only records what's already there, so a new trigger doesn't start a
flow for every old item.

### Webhooks

When the service can call Heddle, a trigger takes a `webhook` instead of `request`
and `poll`. Heddle gives each active trigger an address and a secret. `register` tells
the service about them when the flow is activated, `unregister` when it stops, and
`signature` checks that each event came from the service. `output` picks the items
of an event; each one starts the flow:

```yaml
triggers:
  - name: New Push
    fields:
      - {name: repo, label: Repository}
    webhook:
      register:
        request:
          method: POST
          path: "repos/{{fields.repo}}/hooks"
          body:
            config: {url: "{{webhook.url}}", secret: "{{webhook.secret}}"}
            events: [push]
        id_path: id
      unregister:
        request: {method: DELETE, path: "repos/{{fields.repo}}/hooks/{{webhook.id}}"}
      signature:
        header: X-Hub-Signature-256
        prefix: "sha256="
        secret: "{{webhook.secret}}"
      output:
        path: commits
```

Without `register`, Heddle shows the address and the person pastes it in the service.
A service that makes its own secret returns it at `secret_path`.

A signature with a timestamp, like Stripe's `t=…,v1=…`, takes a `pattern` with the
named groups `signature` and `timestamp`, the `message` that was signed, and how many
seconds old an event may be:

```yaml
signature:
  header: Stripe-Signature
  pattern: "t=(?<timestamp>\\d+),v1=(?<signature>[0-9a-f]+)"
  message: "{{request.timestamp}}.{{request.body}}"
  secret: "{{credential.signing_secret}}"
  tolerance: 300
```

`timestamp_header` reads the timestamp from a header of its own instead. `algorithm`
is `sha1`, `sha256` (the default) or `sha512`, and `encoding` is `hex` (the default)
or `base64`.

A service that calls with a user and a password in `Authorization`, like Pipedrive,
takes `basic`; give the service the same two when registering:

```yaml
signature:
  basic: {username: heddle, password: "{{webhook.secret}}"}
```

Some services check the address before they send anything. `challenge` answers them:

```yaml
challenge:
  query: hub.challenge          # sends this parameter back
  token_query: hub.verify_token # when it matches token
  token: "{{webhook.secret}}"
# or, when the challenge comes in the body:
challenge:
  path: challenge
```

## Other languages

`i18n` holds the texts in other languages, by locale. Heddle shows them to people who
use that language, and the English ones where a text is missing:

```yaml
i18n:
  pt-BR:
    description: Contatos e negócios no Acme.
    actions:
      Create Contact:
        name: Criar contato
        description: Cria um contato.
        fields:
          email: E-mail
```

## Sharing it

To list an integration in Heddle's catalog, add it as `integrations/<id>/integration.yaml`
and open a pull request in [heddlehq/integrations](https://github.com/heddlehq/integrations).

The whole format is in `Bobbin.Integration`, and in
[`priv/integration.schema.json`](https://github.com/heddlehq/Bobbin/blob/main/priv/integration.schema.json)
for editors that read JSON Schema. When a manifest isn't enough, see
[Integrations in Elixir](packages.md).
