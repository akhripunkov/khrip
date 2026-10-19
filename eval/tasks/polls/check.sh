#!/usr/bin/env bash
# Проверка опросов; сервер уже запущен.
. "$(dirname "$0")/../../lib.sh"

check "create" 201 '"id":1 && "question":"Lunch\?" && "closed":false' "${J[@]}" -X POST $U/polls -d '{"question":"Lunch?","options":["pizza","soup","salad"]}'
jtest "create options" "j['options'] == [{'text': 'pizza', 'votes': 0}, {'text': 'soup', 'votes': 0}, {'text': 'salad', 'votes': 0}]"
check "create 2" 201 '"id":2' "${J[@]}" -X POST $U/polls -d '{"question":"Tabs or spaces","options":["tabs","spaces"]}'
check "blank question" 400 '' "${J[@]}" -X POST $U/polls -d '{"question":" ","options":["a","b"]}'
check "one option" 400 '' "${J[@]}" -X POST $U/polls -d '{"question":"q","options":["a"]}'
check "eleven options" 400 '' "${J[@]}" -X POST $U/polls -d '{"question":"q","options":["1","2","3","4","5","6","7","8","9","10","11"]}'
check "blank option" 400 '' "${J[@]}" -X POST $U/polls -d '{"question":"q","options":["a",""]}'
check "same options" 400 '' "${J[@]}" -X POST $U/polls -d '{"question":"q","options":["a","b","a"]}'
check "get" 200 '"id":2 && "question":"Tabs or spaces"' $U/polls/2
check "get missing" 404 '' $U/polls/9
check "vote" 200 '"id":1' "${J[@]}" -H 'X-Voter-Id: ann' -X POST $U/polls/1/votes -d '{"option":1}'
jtest "vote counted" "[o['votes'] for o in j['options']] == [0, 1, 0]"
check "vote 2" 200 '' "${J[@]}" -H 'X-Voter-Id: bob' -X POST $U/polls/1/votes -d '{"option":2}'
check "vote 3" 200 '' "${J[@]}" -H 'X-Voter-Id: cid' -X POST $U/polls/1/votes -d '{"option":1}'
check "twice" 409 '' "${J[@]}" -H 'X-Voter-Id: ann' -X POST $U/polls/1/votes -d '{"option":0}'
check "other poll same voter" 200 '' "${J[@]}" -H 'X-Voter-Id: ann' -X POST $U/polls/2/votes -d '{"option":0}'
check "no voter" 401 '' "${J[@]}" -X POST $U/polls/1/votes -d '{"option":0}'
check "bad option" 400 '' "${J[@]}" -H 'X-Voter-Id: dan' -X POST $U/polls/1/votes -d '{"option":3}'
check "negative option" 400 '' "${J[@]}" -H 'X-Voter-Id: dan' -X POST $U/polls/1/votes -d '{"option":-1}'
check "vote missing poll" 404 '' "${J[@]}" -H 'X-Voter-Id: dan' -X POST $U/polls/9/votes -d '{"option":0}'
check "results" 200 '"total":3' $U/polls/1/results
jtest "results order" "j['results'] == [{'text': 'soup', 'votes': 2, 'percent': 66.7}, {'text': 'salad', 'votes': 1, 'percent': 33.3}, {'text': 'pizza', 'votes': 0, 'percent': 0}]"
check "results empty" 201 '"id":3' "${J[@]}" -X POST $U/polls -d '{"question":"Empty","options":["x","y"]}'
check "results no votes" 200 '"total":0' $U/polls/3/results
jtest "results zero" "[(r['text'], r['votes'], r['percent']) for r in j['results']] == [('x', 0, 0), ('y', 0, 0)]"
check "results missing" 404 '' $U/polls/9/results
check "close" 200 '"id":2 && "closed":true' -X POST $U/polls/2/close
check "close again" 200 '"closed":true' -X POST $U/polls/2/close
check "close missing" 404 '' -X POST $U/polls/9/close
check "vote closed" 403 '' "${J[@]}" -H 'X-Voter-Id: zed' -X POST $U/polls/2/votes -d '{"option":1}'
check "list" 200 '' $U/polls
jtest "list all" "[p['id'] for p in j] == [1, 2, 3]"
check "list open" 200 '' "$U/polls?open=true"
jtest "list open ids" "[p['id'] for p in j] == [1, 3]"
check "list closed" 200 '' "$U/polls?open=false"
jtest "list closed ids" "[p['id'] for p in j] == [2]"
finish
