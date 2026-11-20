# Makes an answer of im.dialog.messages.get fit for the public repository (stage 22).
# The people of users[] become «Тест Пользователь <id>» everywhere, also inside the message texts; e-mails and the
# portal domain disappear; users[] and files[] keep only a short list of fields, the addresses of files are emptied.
# Usage: jq -f scripts/sanitize-im.jq answer.json
def literal($from; $to): split($from) | join($to);

((.result.users // [])
  | map(select(.id != null) | . as $u
      | [{n: ($u.name // ""), r: "Тест Пользователь \($u.id)"},
         {n: ($u.last_name // ""), r: "Тестов\($u.id)"},
         {n: ($u.first_name // ""), r: "Тест\($u.id)"}])
  | add // []
  | map(select(.n | length >= 3))
  | sort_by(.n | length) | reverse) as $pairs
| walk(
    if type == "string" then
      reduce $pairs[] as $p (.; literal($p.n; $p.r))
      # A mention keeps its number and loses the name: system messages name people who are not in users[].
      | gsub("\\[USER=(?<id>[0-9]+)\\][^\\[]*\\[/USER\\]"; "[USER=\(.id)]Тест Пользователь \(.id)[/USER]")
      | gsub("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]+"; "test@example.com")
      | gsub("https?://[A-Za-z0-9.-]*bitrix24[A-Za-z0-9.-]*"; "https://test.bitrix24.kz")
    else . end)
# The card of a system message («создал задачу») repeats the title, the description and the names of the task: the
# product drops system messages (author_id 0), so only the fact that the message is a system one stays.
| if (.result.messages | type) == "array" then
    .result.messages |= map(if .author_id == 0 and (.params | type) == "object" then .params |= del(.ATTACH) else . end)
  else . end
| if (.result.users | type) == "array" then
    .result.users |= map({id, active, name, first_name, last_name, bot, type})
  else . end
| if (.result.files | type) == "array" then
    .result.files |= map(
      .name = ("Тест файл." + (.extension // "bin"))
      | .authorName = "Тест Пользователь \(.authorId)"
      | .urlPreview = "" | .urlShow = "" | .urlDownload = "" | .mediaUrl = ""
      | del(.viewerAttrs))
  else . end
