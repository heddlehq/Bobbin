defmodule Bobbin.Import.OpenAPITest do
  use ExUnit.Case, async: true

  alias Bobbin.Import.OpenAPI
  alias Bobbin.Integration

  @spec_map %{
    "openapi" => "3.0.3",
    "info" => %{"title" => "Pet Store", "description" => "Pets. And more."},
    "servers" => [%{"url" => "https://api.pets.test/v2"}],
    "components" => %{
      "securitySchemes" => %{"key" => %{"type" => "apiKey", "in" => "header", "name" => "X-Key"}},
      "parameters" => %{
        "Limit" => %{"name" => "limit", "in" => "query", "schema" => %{"type" => "integer"}}
      },
      "schemas" => %{
        "NewPet" => %{
          "type" => "object",
          "required" => ["name"],
          "properties" => %{
            "name" => %{"type" => "string", "description" => "The pet's name"},
            "kind" => %{"type" => "string", "enum" => ["cat", "dog"]},
            "vaccinated" => %{"type" => "boolean"},
            "born_at" => %{"type" => "string", "format" => "date-time"},
            "extra" => %{"type" => "object"}
          }
        }
      }
    },
    "paths" => %{
      "/pets" => %{
        "get" => %{
          "operationId" => "listPets",
          "tags" => ["pets"],
          "parameters" => [
            %{"$ref" => "#/components/parameters/Limit"},
            %{"name" => "X-Trace", "in" => "header", "schema" => %{"type" => "string"}}
          ]
        },
        "post" => %{
          "summary" => "Create a pet",
          "tags" => ["pets"],
          "requestBody" => %{
            "content" => %{
              "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/NewPet"}}
            }
          }
        }
      },
      "/pets/{petId}/photo" => %{
        "put" => %{
          "operationId" => "uploadPhoto",
          "tags" => ["photos"],
          "parameters" => [%{"name" => "petId", "in" => "path", "required" => true}],
          "requestBody" => %{
            "content" => %{
              "multipart/form-data" => %{
                "schema" => %{
                  "type" => "object",
                  "properties" => %{"photo" => %{"type" => "string", "format" => "binary"}}
                }
              }
            }
          }
        }
      }
    }
  }

  test "turns a spec into a manifest that checks out" do
    yaml = OpenAPI.convert(@spec_map) |> OpenAPI.to_yaml()
    assert {:ok, i} = Integration.parse(yaml)

    assert i.id == "pet_store"
    assert i.name == "Pet Store"
    assert i.base_url == "https://api.pets.test/v2/"

    assert i.credential.auth == %{
             "type" => "header",
             "name" => "X-Key",
             "value" => "{{credential.api_key}}"
           }

    list = Integration.action(i, "List Pets")
    assert list.resource == "Pets"
    assert list.request.path == "pets"
    assert list.request.query == %{"limit" => "{{fields.limit}}"}
    assert [%{name: "limit", type: "number"}] = list.fields

    create = Integration.action(i, "Create a Pet")
    assert create.request.method == "POST"
    assert create.request.body["name"] == "{{fields.name}}"

    assert %{type: "select", options: [%{"value" => "cat"}, _]} =
             Enum.find(create.fields, &(&1.name == "kind"))

    assert %{required: true} = Enum.find(create.fields, &(&1.name == "name"))
    assert %{type: "boolean"} = Enum.find(create.fields, &(&1.name == "vaccinated"))
    assert %{type: "datetime"} = Enum.find(create.fields, &(&1.name == "born_at"))
    assert %{type: "json"} = Enum.find(create.fields, &(&1.name == "extra"))

    upload = Integration.action(i, "Upload Photo")
    assert upload.request.path == "pets/{{fields.petId}}/photo"
    assert upload.request.body_type == "multipart"
    assert %{type: "file"} = Enum.find(upload.fields, &(&1.name == "photo"))
    assert %{required: true} = Enum.find(upload.fields, &(&1.name == "petId"))
  end

  test "keeps only the tags asked for" do
    yaml = @spec_map |> OpenAPI.convert(tags: ["photos"]) |> OpenAPI.to_yaml()
    assert {:ok, i} = Integration.parse(yaml)
    assert Enum.map(i.actions, & &1.name) == ["Upload Photo"]
  end

  test "maps each kind of security scheme" do
    for {scheme, expected} <- [
          {%{"type" => "http", "scheme" => "bearer"}, "bearer"},
          {%{"type" => "http", "scheme" => "basic"}, "basic"},
          {%{"type" => "apiKey", "in" => "query", "name" => "key"}, "query"},
          {%{
             "type" => "oauth2",
             "flows" => %{
               "authorizationCode" => %{
                 "authorizationUrl" => "https://a.test/auth",
                 "tokenUrl" => "https://a.test/token",
                 "scopes" => %{"read" => "Read"}
               }
             }
           }, "oauth2"},
          {%{
             "type" => "oauth2",
             "flows" => %{"clientCredentials" => %{"tokenUrl" => "https://a.test/token"}}
           }, "client_credentials"}
        ] do
      spec = put_in(@spec_map, ["components", "securitySchemes"], %{"s" => scheme})
      assert {:ok, i} = spec |> OpenAPI.convert() |> OpenAPI.to_yaml() |> Integration.parse()
      assert i.credential.auth["type"] == expected
    end
  end

  test "writes strings YAML would misread in quotes" do
    yaml =
      OpenAPI.to_yaml([{"a", "yes"}, {"b", "1.0"}, {"c", "x: y"}, {"d", ""}, {"e", [1, true]}])

    assert YamlElixir.read_from_string!(yaml) == %{
             "a" => "yes",
             "b" => "1.0",
             "c" => "x: y",
             "d" => "",
             "e" => [1, true]
           }
  end
end
