# Converts a CustomResourceDefinition, one JSON document on the input, into
# the JSON schemas kubeconform reads: one line per entry of spec.versions,
# {"file": "<group>_<kind in lower case>_<version>.json", "schema": ...}.
# Any other document prints nothing. Run it with jq -c.

# strict: closes the schema of an object against unknown fields, as
# kubeconform -strict needs, and admits null where nullable says so. It
# visits the structural positions only: the node, the values of its
# properties, its items and an object additionalProperties. It leaves allOf,
# anyOf, oneOf and not alone, because their branches validate the value of
# the node around them, and closing them would reject valid objects.
def strict:
  if type != "object" then .
  else
    (if has("properties") and (has("additionalProperties") | not)
        and .["x-kubernetes-preserve-unknown-fields"] != true
     then .additionalProperties = false else . end)
    | (if .nullable == true and (.type | type) == "string"
       then .type = [.type, "null"] else . end)
    | (if (.properties | type) == "object" then .properties |= map_values(strict) else . end)
    | (if (.items | type) == "object" then .items |= strict
       elif (.items | type) == "array" then .items |= map(strict)
       else . end)
    | (if (.additionalProperties | type) == "object"
       then .additionalProperties |= strict else . end)
  end;

select(type == "object" and .kind == "CustomResourceDefinition")
| . as $crd
| .spec.versions[]
| if (.schema.openAPIV3Schema | type) != "object" then
    error("CustomResourceDefinition \($crd.metadata.name): version \(.name) has no openAPIV3Schema")
  else
    {file: "\($crd.spec.group)_\($crd.spec.names.kind | ascii_downcase)_\(.name).json",
     schema: (.schema.openAPIV3Schema | strict)}
  end
