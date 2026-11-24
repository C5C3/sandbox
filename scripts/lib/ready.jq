# ready: the status and the first line of the message of the Ready condition
# of the object on the input, or Unknown and "no Ready condition" for an
# object without one.
def ready:
  ([.status.conditions[]? | select(.type == "Ready")][0]) as $c
  | if $c == null then ["Unknown", "no Ready condition"]
    else [$c.status // "Unknown", ($c.message // "" | split("\n")[0] // "")] end;
