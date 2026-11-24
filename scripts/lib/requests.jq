# Sums the memory requests of a pod list, the output of
# `kubectl get pods -o json`, and prints them in bytes, rounded down.
# A sum above 2^53 - 1, the largest integer a jq number holds exactly, is an
# error, so the output is an integer that bash adds without overflow.
#
# It counts the pods that are neither Succeeded nor Failed: their containers
# and their init containers with restartPolicy Always, which run beside them.
# A container without a memory request counts 0.

def factor:
  {"": 1, "Ki": 1024, "Mi": 1048576, "Gi": 1073741824, "Ti": 1099511627776,
   "Pi": 1125899906842624, "Ei": 1152921504606846976,
   "k": 1000, "M": 1000000, "G": 1000000000, "T": 1000000000000,
   "P": 1000000000000000, "E": 1000000000000000000, "m": 0.001}[. // ""];

# bytes($pod): the bytes of the quantity on the input; $pod names it in an error.
# The quantity has a binary or decimal suffix, or a decimal exponent such as
# 129e6, which the API server returns in the form it was written in.
def bytes($pod):
  if . == null then 0
  else
    tostring as $quantity
    | ($quantity | capture("^(?<number>[0-9]+(\\.[0-9]+)?)(?:[eE](?<exponent>[+-]?[0-9]+)|(?<suffix>Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E|m))?$"))
      // error("unsupported memory quantity \($quantity) in pod \($pod.metadata.namespace)/\($pod.metadata.name)")
    | (.number | tonumber) * (if .exponent then pow(10; .exponent | tonumber) else (.suffix | factor) end)
  end;

[
  (.items // [])[]
  | select(.status.phase != "Succeeded" and .status.phase != "Failed")
  | . as $pod
  | (.spec.containers // [])[], ((.spec.initContainers // [])[] | select(.restartPolicy == "Always"))
  | .resources.requests.memory
  | bytes($pod)
]
| add // 0
| floor
| if . > 9007199254740991 then error("memory requests of \(.) bytes are too large to sum") else . end
