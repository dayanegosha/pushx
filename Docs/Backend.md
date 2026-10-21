# pushx · сервер и API

Серверная часть подготовлена для Supabase: Auth с Apple, PostgreSQL с RLS и Edge Function удаления аккаунта. Она **не развёрнута**: в комплекте нет проекта Supabase, ключей Apple или работающего публичного адреса. При первом запуске Release обязателен вход с Apple: счётчик и история открываются после получения сессии. Без развёрнутого сервера и публичной конфигурации экран входа не пропускает дальше — это блокирующая задача перед релизом. Только Debug-флаг `UPRA_LOCAL_PREVIEW=1` разрешает локальную проверку интерфейса. Подписка не требуется для счётчика, друзей и рейтинга.

## Развёртывание

1. Создайте проект Supabase в выбранном регионе. В Apple Developer создайте App ID с Sign in with Apple и подходящий Sign in with Apple `.p8` ключ. Bundle ID приложения и `APPLE_CLIENT_ID` должны совпадать; Team ID в client ID не добавляется.
2. В Supabase Authentication → Providers включите Apple и добавьте Bundle ID в разрешённые client IDs для нативного входа. Отключите неиспользуемые способы регистрации, включая анонимные аккаунты. Если дополнительно используется веб OAuth, настройте Services ID, callback и ротацию его client secret отдельно.
3. Установите Supabase CLI и из каталога `Backend` выполните:

   ```sh
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   supabase db push
   ```

4. Скопируйте `.env.example` в локальный `.env`, заполните `APPLE_CLIENT_ID`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` всем содержимым PKCS#8 `.p8`. Файл игнорируется Git. Supabase сам предоставляет `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` Edge Function. Не помещайте эти серверные секреты в iOS или `.xcconfig` приложения.
5. Загрузите секреты и функцию:

   ```sh
   supabase secrets set --env-file .env
   supabase functions deploy delete-account
   ```

   `verify_jwt = false` в `supabase/config.toml` применяется намеренно: обработчик самостоятельно проверяет Bearer через Auth `/user` и получает актуальные provider identities. Запрос без действующей сессии не проходит. Это совместимо с асимметричными JWT проекта и старым HS256.
6. В iOS задайте только публичные URL проекта и anon/publishable key. На устройстве проверьте вход Apple, восстановление сессии, синхронизацию, дружбу между двумя аккаунтами и полное удаление тестового аккаунта с последующим повторным входом Apple.
7. Перед публикацией настройте мониторинг ошибок и резервного копирования, ограничения запросов на API gateway/WAF, а также проверку сетевой доступности в целевых странах. Встроенный лимит заявок ограничивает успешные новые запросы; он не заменяет периметровый лимит перебора несуществующих friend codes. Проверяйте актуальные тарифы, квоты, регион хранения и условия поставщика перед коммерческим запуском.

Ни `.p8`, ни service role key, ни содержимое ID token/authorization code не должны попадать в логи, аналитику или клиентскую сборку. В функции нет журналирования этих данных. Для нативного приложения `Origin` отсутствует; браузерные запросы разрешены только из точного списка `ALLOWED_ORIGINS`, разделённого запятыми. Пустой список запрещает все браузерные origins. `*` не используется.

## Вход и сессия

Нативный клиент создаёт криптографически случайный `rawNonce`, передаёт SHA-256 `rawNonce` в `ASAuthorizationAppleIDRequest.nonce`, затем отправляет **исходный** nonce в Supabase:

```http
POST /auth/v1/token?grant_type=id_token
apikey: PUBLIC_PROJECT_KEY
Content-Type: application/json

{"provider":"apple","id_token":"APPLE_IDENTITY_TOKEN","nonce":"RAW_NONCE"}
```

Стандартный ответ Supabase содержит `access_token`, `refresh_token`, `expires_in`, `token_type`, `user.id`. Refresh:

```http
POST /auth/v1/token?grant_type=refresh_token
apikey: PUBLIC_PROJECT_KEY
Content-Type: application/json

{"refresh_token":"REFRESH_TOKEN"}
```

Храните токены в Keychain, обновляйте сессию до истечения/после 401 с единственной повторной попыткой. Из ответа refresh сохраняются оба новых токена. Локальная история должна оставаться привязана к владельцу, чтобы при смене Apple аккаунта результаты одного человека не загрузились другому. Самостоятельное назначение другого `user_id` серверным RPC не поддерживается.

Apple передаёт имя при первом разрешении на вход. Клиент запрашивает `.fullName` без email scope и сохраняет имя в Keychain по Apple subject **до** сетевого обмена. После получения профиля имя импортируется через `set_display_name` с `p_only_if_empty: true`, поэтому параллельный вход не перезапишет уже изменённое имя. Обычное редактирование в настройках передаёт `false`. При выходе локальный кеш имени сохраняется; при успешном удалении аккаунта удаляется вместе с сессией.

`set_display_name` не принимает user ID: владелец определяется через `auth.uid()`. Имя приводится к NFC, Unicode-пробелы схлопываются в один обычный пробел, пробелы по краям удаляются. Допускается 1–64 Unicode scalar values; оставшиеся управляющие, нулевой ширины и bidi-контроли отвергаются с `invalid_display_name`. Это отображаемое имя, оно не используется для авторизации и не обязано быть уникальным.

## Общий формат API

Все RPC — `POST https://PROJECT.supabase.co/rest/v1/rpc/FUNCTION`:

```http
apikey: PUBLIC_PROJECT_KEY
Authorization: Bearer USER_ACCESS_TOKEN
Content-Type: application/json
```

JSONB-функции возвращают непосредственно объект/массив ниже, без `data`-обёртки. `void`-функции требуют успешный HTTP 2xx; тело игнорируется. UUID — строки, timestamps — ISO 8601 с часовым поясом, даты — `YYYY-MM-DD`. Поля, не перечисленные в контракте, клиенту не нужны.

| RPC | JSON запроса | JSON ответа |
| --- | --- | --- |
| `get_profile` | `{}` | `{"id":"UUID","friend_code":"0A1B2C3D4E","created_at":"2026-10-18T10:00:00+00:00","display_name":"Георгий"}` |
| `set_display_name` | `{"p_display_name":"Георгий","p_only_if_empty":false}` | тот же объект, что `get_profile` |
| `get_friends` | `{}` | `[{"user_id":"UUID","friend_code":"1A2B3C4D5E","display_name":"Александр","status":"accepted","requested_at":"2026-10-18T10:00:00+00:00"}]` |
| `get_blocked_users` | `{}` | `[{"user_id":"UUID","friend_code":"1A2B3C4D5E","display_name":"Александр"}]`, только собственный список блокировок |
| `request_friend` | `{"p_friend_code":"1A2B3C4D5E"}` | JSON-строка: `"outgoing"`, `"incoming"` или `"accepted"` |
| `respond_friend_request` | `{"p_user_id":"UUID","p_accept":true}` | void |
| `remove_friend` | `{"p_user_id":"UUID"}` | void; также отменяет свою исходящую заявку |
| `block_user` | `{"p_user_id":"UUID"}` | void; удаляет дружбу/заявку и закрывает новые заявки в обе стороны |
| `unblock_user` | `{"p_user_id":"UUID"}` | void; снимает только свою блокировку, дружбу не восстанавливает |
| `get_daily_leaderboard` | `{"p_day":"2026-10-18"}` | `[{"user_id":"UUID","friend_code":"0A1B2C3D4E","display_name":"Георгий","repetitions":42,"rank":1,"is_me":true}]` |

`get_friends.status` принимает `accepted`, `incoming`, `outgoing`. Встречная заявка не принимается автоматически: получатель явно вызывает `respond_friend_request`. Принять собственную заявку нельзя. Удаление и блокировка идемпотентны. Friend code — десять заглавных hex-символов; ввод нормализуется по регистру и пробелам по краям. В соревновании отображается имя; код остаётся для поиска и добавления друзей. Фотографии не загружаются. Поле `display_name` может быть `null` у старого профиля; клиент показывает локализованную подпись «Участник», не подставляет код вместо имени. Профили нельзя перечислить через таблицу; поиск работает только по точному коду.

Ограничения: 100 подтверждённых друзей, 20 исходящих ожидающих заявок, 30 новых успешных заявок в час на пользователя. Повторная отправка существующей заявки не создаёт новую. Таблица `user_blocks` доступна на чтение только блокирующему, поля `blocker_id`, `blocked_id`, `created_at`. Табличные изменения с клиента запрещены.

## Тренировки и рейтинг

```http
POST /rest/v1/rpc/upload_workout

{
  "p_id":"68cb637b-b923-4b13-b9e5-896caf16de2b",
  "p_started_at":"2026-10-18T10:00:00Z",
  "p_ended_at":"2026-10-18T10:01:00Z",
  "p_repetitions":30,
  "p_detection_mode":"camera"
}
```

Ответ:

```json
{
  "id":"68cb637b-b923-4b13-b9e5-896caf16de2b",
  "started_at":"2026-10-18T10:00:00+00:00",
  "ended_at":"2026-10-18T10:01:00+00:00",
  "repetitions":30,
  "detection_mode":"camera",
  "day_utc":"2026-10-18",
  "received_at":"2026-10-18T10:01:02+00:00"
}
```

Клиент генерирует UUID один раз при сохранении тренировки и сохраняет точные timestamps. Повтор с тем же UUID и тем же содержимым возвращает прежний результат, включая `received_at`. Попытка заменить тренировку или использовать UUID другого владельца отвергается. Проверка повтора выполняется до проверки давности: безопасная повторная доставка уже принятой старой тренировки разрешена.

Правила загрузки: 1–600 повторений; режим `camera` или `touch`; длительность от 0,5 секунды на повтор до 6 часов; окончание не старше 30 дней и не дальше 5 минут в будущем; не более 5000 повторений на день UTC; интервалы тренировок одного пользователя не пересекаются. Соседние интервалы с общей границей разрешены. Записи не редактируются. При отклонении сервером тренировка должна сохраняться локально с ошибкой синхронизации. Нулевые сессии в облако не отправляются.

Эти проверки устраняют часть дубликатов и очевидных ошибок. Они не доказывают выполнение упражнения: модифицированный клиент способен отправить вымышленные результаты. Рейтинг предназначен для дружеских соревнований, без призов и денежных ставок.

История своего аккаунта:

```http
GET /rest/v1/workouts?select=id,started_at,ended_at,repetitions,detection_mode,day_utc,received_at&order=ended_at.desc,id.desc&limit=1000&offset=0
```

Ответ — JSON-массив с той же формой объекта тренировки. Следующие страницы — `offset=1000`, `2000` и т. д. RLS ограничивает выборку владельцем; фильтр `user_id` не нужен и не позволяет прочесть чужие данные. Во время обновления может потребоваться повторная сверка по UUID, если новые записи сдвинули границы страниц.

Все соревнования используют **UTC**: `day_utc` вычисляет PostgreSQL из `ended_at`, независимо от локального часового пояса и даты получения сервером. Сессия через полночь целиком относится ко дню окончания. Офлайн-загрузка в пределах 30 дней может изменить прошлый результат. Для текущего рейтинга клиент передаёт текущую дату UTC и обновляет её после UTC-полуночи. Запрос рейтинга допускает сегодня и предыдущие 366 дней. Личная локальная статистика может группироваться по часовому поясу пользователя, поэтому её границы дня могут отличаться.

В рейтинге участвует пользователь и его текущие подтверждённые друзья; заявки и блокировки исключены. Видны только агрегаты за день, а не чужие отдельные тренировки. При равенстве повторений у участников одинаковое место (`dense_rank`), вторичная сортировка по коду обеспечивает стабильность. Дружба не фиксируется исторически: после удаления друг исчезает и из просмотра прежних дней.

## Удаление аккаунта

Клиент перед удалением выполняет **новую** авторизацию Apple, не меняя текущую Supabase сессию, и отправляет её свежие credentials:

```http
POST /functions/v1/delete-account
apikey: PUBLIC_PROJECT_KEY
Authorization: Bearer USER_ACCESS_TOKEN
Content-Type: application/json

{"authorizationCode":"FRESH_APPLE_CODE","idToken":"FRESH_APPLE_IDENTITY_TOKEN"}
```

Последовательность сервера:

1. Auth `/user` проверяет сессию и возвращает текущие Apple identities. Клиентский `user_id` и редактируемый `user_metadata` не используются.
2. `jose` проверяет Apple ID token по публичным ключам Apple, `RS256`, issuer `https://appleid.apple.com`, audience `APPLE_CLIENT_ID`, срок действия и обязательные `sub`, `iat`, `exp`. `iat` должен быть не старше 5 минут; допустимый сдвиг часов вперёд — 30 секунд. Subject должен совпасть с Apple identity аккаунта Supabase.
3. Одноразовый Apple authorization code обменивается на токены через `/auth/token` с серверным ES256 client secret. Возвращённый Apple ID token также проверяется и сравнивается по `sub`, исключая подмену кода от другого пользователя.
4. Apple refresh token (либо access token при отсутствии refresh) отзывается через `/auth/revoke`.
5. Только после успешного отзыва вызывается Auth Admin DELETE. Каскад удаляет профиль, тренировки, заявки, дружбу, блокировки и события ограничителя.

Успех — HTTP 200 `{"deleted":true}`. Затем клиент удаляет локальные данные аккаунта и Keychain сессию. Подписка App Store управляется отдельно пользователем через Apple: удаление аккаунта не отменяет её автоматически.

Сетевой сбой не выдаётся за успех. После обмена одноразовый code повторно не работает: для повторной попытки удаления нужна новая авторизация Apple. Если отзыв прошёл, но Auth Admin DELETE завершился ошибкой, аккаунт остаётся на сервере до успешного повтора. Если ответ успешного удаления потерялся по сети, повторное получение Auth `/user` уже не найдёт аккаунт; клиент должен обработать это как истёкшую сессию и предложить повторный вход/проверку. Этот сценарий требуется проверить на устройстве перед релизом.

JWT уже удалённого пользователя может формально оставаться криптографически действительным до `exp`. Таблицы удалены, а каждый RPC дополнительно требует существующий живой профиль, поэтому повторные записи этим JWT не принимаются. Сервер не использует Supabase Storage; если его добавить, удаление объектов должно предшествовать удалению Auth пользователя.

## Ошибки

PostgREST возвращает стандартный объект `{"code":"22023","message":"invalid_workout","details":null,"hint":null}`. Стабильные `message`:

| Код SQL | Сообщения |
| --- | --- |
| `42501` | `authentication_required` |
| `22023` | `invalid_friend_code`, `friend_unavailable`, `too_many_pending_requests`, `friend_limit_reached`, `friend_request_rate_limit`, `invalid_friend_request`, `friend_request_not_found`, `invalid_user`, `invalid_workout`, `workout_id_conflict`, `workout_time_overlap`, `daily_limit_reached`, `invalid_day`, `invalid_display_name` |

Edge Function возвращает `{"error":"CODE"}`:

| HTTP | CODE |
| --- | --- |
| 400 | `invalid_request`, `apple_authorization_failed` |
| 401 | `authentication_required`, `apple_reauthentication_required` |
| 403 | `apple_identity_mismatch`, `origin_not_allowed` |
| 405 | `method_not_allowed` |
| 502 | `apple_revocation_failed`, `account_deletion_failed` |
| 503 | `service_unavailable`, `service_not_configured` |

Supabase Auth и gateway могут вернуть собственные ошибки до функции. Клиенту следует показывать локализованный общий текст для неизвестных кодов, не отображать пользователю содержимое токенов или необработанные диагностические ответы.

## Проверки

В поставке есть SQL regression и 10 тестов последовательности удаления. Они были выполнены локально: PostgreSQL 17.10 с минимальной Auth fixture и Node.js 24.21.0; Edge adapter также прошёл `deno check` на Deno 2.5.6. Проверены RLS, запрет прямой записи/анонимного доступа, заявки/принятие/блокировка, изоляция рейтинга, идемпотентность, пределы тренировок, каскад удаления и отказ старому JWT удалённого пользователя. Тесты Edge изолируют адаптеры сети и JWT: это проверка порядка и отказов, не живой запрос Apple.

Команда Edge-тестов из каталога `Backend`:

```sh
node --experimental-strip-types --test tests/delete-account.test.ts
```

SQL-тесты запускайте **только в пустой одноразовой локальной БД**, так как `bootstrap.sql` создаёт тестовые роли и Auth schema:

```sh
psql "$DISPOSABLE_DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/bootstrap.sql -f supabase/migrations/202610180001_forma.sql -f supabase/migrations/202610210001_profile_display_names.sql -f tests/regression.sql
```

На настоящем локальном Supabase bootstrap не применяется; Auth и роли уже создаёт платформа. Для проверки Deno adapter:

```sh
deno check --config supabase/functions/delete-account/deno.json supabase/functions/delete-account/index.ts
supabase functions serve delete-account --env-file .env
```

Нужны отдельные интеграционные проверки в вашем Supabase и на физическом iPhone: реальные Apple токены, завершение/отказ Apple revocation, свежий код после сетевого сбоя, сессии после удаления и смена пользователя. Для App Store укажите реальную политику конфиденциальности, контакты поддержки, фактические сроки хранения резервных копий и обработки запросов удаления. Отдельные тренировки и friend graph хранятся до удаления аккаунта; снимки резервных копий следуют настроенному сроку хранения провайдера.

## Первичные источники

Поток nonce соответствует [Supabase native ID token sign-in](https://supabase.com/docs/reference/swift/auth-signinwithidtoken). Проверка текущего пользователя через сеть описана в [Supabase getUser](https://supabase.com/docs/reference/javascript/auth-getuser), модель доверенных identities — в [Supabase Identities](https://supabase.com/docs/guides/auth/identities). Обмен кода и отзыв токенов соответствуют [Apple Token validation](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens) и [Apple Token revocation](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens). Правила server-only удаления — [Supabase deleteUser](https://supabase.com/docs/reference/javascript/auth-admin-deleteuser), особенности оставшегося JWT — [Supabase user management](https://supabase.com/docs/guides/auth/managing-user-data).
