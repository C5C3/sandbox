# Turns the Flux objects of flux-system on sandbox-management, the output of
# `kubectl get -o json` for FluxInstances, OCIRepositories and
# Kustomizations, into the rows of make status. $clusters names the roles
# whose cluster exists, separated by spaces.
#
# A row is the cluster, <Kind>/<name>, the status of the Ready condition and
# the first line of its message, separated by tabs. The FluxInstance and the
# OCIRepository come first, under management. Then, per role, come the root
# cluster-<role> and the stages labelled with the role, sorted by name; an
# existing cluster without a root has the row "<role> - - not attached to the
# hub". A Kustomization of no role comes last, under -.

include "ready" {search: "./"};

def roles: ["management", "storage", "compute"];

def role_label: .metadata.labels["sandbox.c5c3.io/cluster"] // "";

def row($cluster): [$cluster, "\(.kind)/\(.metadata.name)"] + ready | @tsv;

def of_kind($kind): map(select(.kind == $kind)) | sort_by(.metadata.name)[];

(.items // []) as $items
| ($clusters | split(" ")) as $existing
| [$items[] | select(.kind == "Kustomization")] as $kustomizations
| ($items | of_kind("FluxInstance") | row("management")),
  ($items | of_kind("OCIRepository") | row("management")),
  (roles[] as $role
   | ([$kustomizations[] | select(.metadata.name == "cluster-\($role)")][0]) as $root
   | (if $root != null then $root | row($role)
      elif any($existing[]; . == $role) then [$role, "-", "-", "not attached to the hub, run make up-\($role)"] | @tsv
      else empty end),
     ($kustomizations
      | map(select(role_label == $role and .metadata.name != "cluster-\($role)"))
      | sort_by(.metadata.name)[] | row($role))),
  ($kustomizations
   | map(select(
       (.metadata.name as $name | any(roles[]; $name == "cluster-\(.)") | not)
       and (role_label as $label | any(roles[]; . == $label) | not)))
   | sort_by(.metadata.name)[] | row("-"))
