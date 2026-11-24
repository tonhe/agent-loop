# Turn the GraphQL answer of scripts/native-blockers.sh into the $native map used by
# blocked.jq.
# Input (slurped, one element per page):
#   [ {"data": {"repository": {"issues": {"nodes": [
#        {"number": N, "blockedBy": {"totalCount": T, "nodes": [{"number": M, "state": "OPEN"|"CLOSED"}]}}
#     ]}}}} ]
# Output: {"<N>": [numbers of OPEN blockers]}; issues with no open blocker are left out.
# A blocker list longer than the page that was fetched adds -1 (unknown, so blocked).
# Fails (non-zero exit) on an empty or error answer, so the caller can degrade.
if length == 0 or any(.[]; .errors != null or .data.repository.issues.nodes == null)
then error("no usable dependency data")
else
  [ .[].data.repository.issues.nodes[]
    | {key: (.number | tostring),
       value: ([.blockedBy.nodes[]? | select(.state == "OPEN") | .number]
               + (if (.blockedBy.totalCount // 0) > ((.blockedBy.nodes // []) | length) then [-1] else [] end))}
    | select(.value | length > 0)
  ] | from_entries
end
