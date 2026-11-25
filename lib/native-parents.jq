# Turn the GraphQL answer of scripts/native-parents.sh into the $parents map used by
# paired.jq.
# Args:  --arg repo OWNER/NAME
# Input (slurped, one element per page):
#   [ {"data": {"repository": {"issues": {"nodes": [
#        {"number": N, "parent": null | {"number": P, "repository": {"nameWithOwner": "OWNER/NAME"}}}
#     ]}}}} ]
# Output: {"<N>": P}; issues without a parent are left out, and so is a parent in another
# repository (its number means nothing here).
# Fails (non-zero exit) on an empty or error answer, so the caller can degrade.
if length == 0 or any(.[]; .errors != null or .data.repository.issues.nodes == null)
then error("no usable sub-issue data")
else
  [ .[].data.repository.issues.nodes[]
    | select((.parent.number | type) == "number")
    | select(((.parent.repository.nameWithOwner // "") | ascii_downcase) == ($repo | ascii_downcase))
    | {key: (.number | tostring), value: .parent.number}
  ] | from_entries
end
