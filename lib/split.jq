# Large pull requests: plan how a review is split into several Claude calls.
# Pure functions: `git diff --numstat` text in, a list of groups out. Nothing here runs
# git or reads the repository. File names are data and are only ever compared and copied.
#
#   git -c core.quotePath=false diff --numstat --no-renames BASE...HEAD \
#     | jq -Rs 'include "split"; parse_numstat | split_plan(40; 3000; 8)'

# c_unquote: a path as git prints it -> the real path. git prints a name that contains
# a quote, a backslash or a control character in C-quoted form ("a\"b", "a\nb",
# "a\001b"). With core.quotePath=false bytes above 0x7f are not escaped, so every
# octal escape is one character.
def c_unquote:
  if length >= 2 and startswith("\"") and endswith("\"") then
    .[1:-1]
    | [match("\\\\[0-7]{3}|\\\\[\\s\\S]|[^\\\\]+"; "g").string
       | if startswith("\\") then
           .[1:] as $e
           | if ($e | test("\\A[0-7]{3}\\z")) then [($e | explode | map(. - 48) | .[0] * 64 + .[1] * 8 + .[2])] | implode
             else ({"a": "\u0007", "b": "\b", "t": "\t", "n": "\n", "v": "\u000b", "f": "\f", "r": "\r"}[$e] // $e) end
         else . end]
    | join("")
  else . end;

# parse_numstat: numstat text -> [{path, binary, lines}], lines = added + deleted.
# A binary file ("-\t-\tpath") has no line counts: it counts as a file with 0 lines.
# Run git with --no-renames so every line is one path. Lines of any other shape are dropped.
def parse_numstat:
  [ (. // "") | split("\n")[]
    | capture("\\A(?<a>[0-9]+|-)\\t(?<d>[0-9]+|-)\\t(?<p>[\\s\\S]+)\\z")
    | {path: (.p | c_unquote),
       binary: (.a == "-" or .d == "-"),
       lines: (if .a == "-" or .d == "-" then 0 else (.a | tonumber) + (.d | tonumber) end)} ];

def _lines: map(.lines) | add // 0;
def _fits($mf; $ml): length <= $mf and _lines <= $ml;

# Files that sit directly in one directory cannot be divided by directory: cut the list,
# in path order, into runs that fit. A single file over the line threshold is a run of one.
def _chunks($mf; $ml):
  reduce .[] as $f ([];
    if length > 0 and (.[-1] | length) < $mf and ((.[-1] | _lines) + $f.lines) <= $ml
    then .[:-1] + [.[-1] + [$f]] else . + [[$f]] end);

# _leaves($d): files that share their first $d path components -> [{name, files}].
# A set that fits (or is a single file) is one leaf. Otherwise the files directly in
# this directory become their own leaf or leaves, and each subdirectory is looked at
# again one level deeper.
def _leaves($d; $mf; $ml):
  if _fits($mf; $ml) or length <= 1 then
    [{name: (if $d == 0 then "all" else (.[0].parts[:$d] | join("/")) + "/" end), files: .}]
  else
    (if $d == 0 then "(root files)" else (.[0].parts[:$d] | join("/")) + "/ (files)" end) as $dname
    | (map(select((.parts | length) == $d + 1)) | _chunks($mf; $ml)) as $direct
    | ($direct | length) as $n
    | [ $direct | to_entries[]
        | {name: ($dname + (if $n > 1 then " part \(.key + 1)/\($n)" else "" end)), files: .value} ]
      + [ map(select((.parts | length) > $d + 1)) | group_by(.parts[$d])[] | _leaves($d + 1; $mf; $ml)[] ]
  end;

def _bin: {names: [.name], paths: (.files | map(.path)), plines: (.files | map(.lines)), files: (.files | length), lines: (.files | _lines)};
def _merge($a; $b):
  {names: ($a.names + $b.names), paths: ($a.paths + $b.paths), plines: ($a.plines + $b.plines), files: ($a.files + $b.files), lines: ($a.lines + $b.lines)};

# First fit, in path order: a group joins the first earlier bin it fits into.
def _pack($mf; $ml):
  reduce .[] as $g ([];
    ([range(0; length) as $i | select(.[$i].files + $g.files <= $mf and .[$i].lines + $g.lines <= $ml) | $i] | .[0]) as $i
    | if $i == null then . + [$g] else .[$i] = _merge(.[$i]; $g) end);

# More bins than calls allowed: merge the two smallest until the number fits.
def _cap($n):
  if length <= $n then .
  else (sort_by(.lines, .files, .paths[0]) as $s | [_merge($s[0]; $s[1])] + $s[2:]) | _cap($n) end;

def _name: .names | if length <= 3 then join(", ") else (.[:3] | join(", ")) + " and \(length - 3) more" end;

# split_plan($max_files; $max_lines; $max_calls): [{path, lines, ...}] ->
#   {split, capped, uncapped, total_files, total_lines, groups: [{name, paths, files, lines}]}
#
#   - at or under both thresholds: one group ("all"), split false.
#   - over either: group by top-level directory; root-level files are their own group. A
#     group that is itself over a threshold is divided one level deeper, and so on, until
#     every group fits or is a single file. Small groups are then packed together.
#   - more groups than $max_calls: the smallest are merged until the number fits; capped
#     is true and uncapped is the number before merging. A merged group may be over the
#     thresholds; the per-call diff size cap in review-prompts.sh still applies to it.
#   split is true when the review needs more than one call. Every file is in exactly one
#   group. Thresholds below 1 count as 1.
def split_plan($max_files; $max_lines; $max_calls):
  ([$max_files, 1] | max) as $mf | ([$max_lines, 1] | max) as $ml | ([$max_calls, 1] | max) as $mc
  | map(. + {parts: (.path | split("/"))}) | sort_by(.path)
  | {total_files: length, total_lines: _lines} as $t
  | (if _fits($mf; $ml) then [{name: "all", files: .} | _bin]
     else _leaves(0; $mf; $ml) | map(_bin) | _pack($mf; $ml) end) as $packed
  | ($packed | _cap($mc) | sort_by(.paths[0])) as $groups
  | $t + {split: (($groups | length) > 1),
          capped: (($packed | length) > $mc),
          uncapped: ($packed | length),
          groups: ($groups | map({name: _name, paths, plines, files, lines}))};
# plines: changed lines per path, in the order of paths (refine_plan needs them).

# refine_plan($sizes; $cap; $max_calls): a plan -> a plan in which a group whose diff is
# larger than $cap bytes is cut, in path order, into runs of files whose diffs fit.
#   $sizes: {"<group index>": [diff bytes per path, in the order of that group's paths]},
#           given only for the groups that are over the cap (review-prompts.sh measures).
# Nothing is dropped: the point is that no diff has to be truncated when a finer split
# avoids it. Two limits remain, and both leave a group over the cap for the caller to
# deal with: a single file cannot be split, and the plan never grows beyond $max_calls
# groups (when the room runs out, the last run takes the rest of the files).
def refine_plan($sizes; $cap; $max_calls):
  . as $plan
  | (reduce (.groups | to_entries[]) as $e ({out: [], extra: 0};
      $sizes[$e.key | tostring] as $s
      | ([$max_calls - ($plan.groups | length) - .extra, 0] | max) as $room
      | if $s == null or ($e.value.paths | length) < 2 or $room < 1 then .out += [$e.value]
        else
          ( [range(0; $e.value.paths | length) as $k
              | {path: $e.value.paths[$k], lines: ($e.value.plines[$k] // 0), bytes: ($s[$k] // 0)}]
            | reduce .[] as $f ([];
                if length > 0 and (length > $room or ((.[-1] | map(.bytes) | add) + $f.bytes) <= $cap)
                then .[:-1] + [.[-1] + [$f]] else . + [[$f]] end) ) as $chunks
          | ($chunks | length) as $n
          | .extra += $n - 1
          | .out += [ $chunks | to_entries[]
                      | {name: (if $n > 1 then "\($e.value.name) (part \(.key + 1)/\($n))" else $e.value.name end),
                         paths: (.value | map(.path)), plines: (.value | map(.lines)),
                         files: (.value | length), lines: (.value | map(.lines) | add)} ]
        end)
     | .out) as $groups
  | $plan + {groups: $groups, split: (($groups | length) > 1)};
