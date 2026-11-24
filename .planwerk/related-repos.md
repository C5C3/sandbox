# Related repositories

## C5C3/cobaltcore

When: the work finds a gap or a defect in upstream that the sandbox cannot
close on its own side. That is the case when a point from "Points to prove
first" of the README fails, or holds only with a workaround, because of
upstream behavior; when an upstream base, chart, CRD, operator or guide has to
change before a module of the sandbox works; or when a patch in the sandbox
carries something upstream should carry itself.
Not when: the difference is specific to kind or to the split across three
clusters and the sandbox patches it as designed, or the change only moves the
upstream pin.

## C5C3/playground

When: the work corrects or improves something the sandbox took over from the
playground and that the playground has in the same form: the Flux stages per
cluster, the inclusion of upstream, the bootstrap steps as Jobs, the
validation script.
Not when: the change concerns only what the sandbox adds on its own: kind, the
OCI artifact of the working tree in a local registry, the modules and
profiles, the split across three clusters.
