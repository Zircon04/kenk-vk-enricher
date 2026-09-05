# kenk-vk-enricher

Эта версия — форк [alexbatishchev/kenk-vk-enricher](https://github.com/alexbatishchev/kenk-vk-enricher).
Добавлены режим без видео, выбор переписок, авторизация Firefox для веб-запросов,
скрипты повторного запуска и монитор прогресса. Инструкция: [FORK.md](FORK.md).

В исходном репозитории лицензия не указана. Этот форк не меняет права на исходный
код и не объявляет его распространяемым под MIT или другой новой лицензией.

Скрипт для локального сохранения медиаданных из выгрузки ВКонтакте.

---

## О проекте

ВКонтакте позволяет запросить выгрузку личных данных через страницу [vk.com/data_protection](https://vk.com/data_protection). Через некоторое время вы получаете zip-архив с набором HTML-страниц — перепиской, стеной, фотоальбомами, видео и другим. Однако сами медиафайлы (фотографии, видео, прикреплённые документы) в архив не входят: вместо них HTML-страницы содержат ссылки на серверы ВКонтакте.

Это означает, что такой архив:
- не работает без интернета
- перестанет работать, если ВКонтакте закроет доступ к файлам
- не является полноценной независимой копией ваших данных

**kenk-vk-enricher** решает эту проблему: скрипт парсит дамп, скачивает все доступные медиафайлы и переписывает HTML так, чтобы всё открывалось с диска без подключения к интернету.

---

## Как работает скрипт

```
 vk-export.zip
      │
      │ -Init
      ▼
┌─────────────────────┐
│   папка профиля     │
│   (.source/)        │
└──────────┬──────────┘
           │ запуск без -Init
           ▼
┌─────────────────────────────────────────┐
│  heal базы данных (.data/files.json)    │
│  · восстановление после повреждений     │
│  · дедупликация записей                 │
│  · восстановление пропавших записей     │
│    по файлам на диске                   │
│  · удаление дублей видеофайлов          │
└──────────┬──────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────┐
│  Pass 1: переписка + стена                           │
│  скачивает новые фото/файлы/видео inline             │
│  (видео с ошибкой в базе — пропускаются)             │
└──────────┬───────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────┐
│  фотоальбомы → скачивает фото → ctx.RemoteLocalPhotos│
│  видеоальбомы → скачивает видео                      │
└──────────┬───────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────┐
│  Pass 2: переписка + стена — повторно                │
│  теперь ctx.RemoteLocalPhotos заполнен →             │
│  фото из альбомов подставляются в переписку/стену    │
│  видео — из кэша базы (скачаны в pass 1)             │
└──────────┬───────────────────────────────────────────┘
           │
           ▼
    HTML переписан:
    ссылки на ВК → локальные файлы
           │
           ▼
    index.html — открывать в браузере
```

Для каждого видео в HTML скрипт проверяет базу и выводит один из статусов:

| Статус | Значение |
|---|---|
| `✅ video file [...] downloaded` | видео только что скачано через yt-dlp |
| `⏭ video unavailable (cached) [...]` | в базе зафиксирована ошибка, перекачка не запрошена — норма |
| `❌ error downloading video [...]` | попытка скачать прямо сейчас завершилась ошибкой |

---

## Требования

- Windows 10 или 11
- PowerShell 5.1 или новее
- [`yt-dlp.exe`](https://github.com/yt-dlp/yt-dlp/releases) и [`ffmpeg.exe`](https://ffmpeg.org/download.html) — положить в папку рядом со скриптом (нужны для скачивания видео)
- Google Chrome — должен быть установлен и залогинен в ВКонтакте (нужен для скачивания видео, доступного только авторизованным пользователям)

---

## Быстрый старт

### Шаг 1 — Запросите выгрузку данных в ВК

Перейдите на [vk.com/data_protection](https://vk.com/data_protection), запросите архив и дождитесь, когда он будет готов к скачиванию.

### Шаг 2 — Инициализируйте профиль

```powershell
.\kenk-vk-enricher.ps1 -Init "D:\downloads\vk-export.zip"
```

Это распакует архив в папку профиля. По умолчанию имя профиля берётся из имени zip-файла. Чтобы задать имя явно:

```powershell
.\kenk-vk-enricher.ps1 -Init "D:\downloads\vk-export.zip" -Profile "my_vk"
```

### Шаг 3 — Запустите обработку

```powershell
.\kenk-vk-enricher.ps1 -Profile "my_vk"
```

Или по полному пути к папке профиля:

```powershell
.\kenk-vk-enricher.ps1 -Profile "D:\path\to\profile-folder"
```

Скрипт скачает все медиафайлы и перепишет HTML. Это может занять значительное время — особенно если в дампе много видео.

### Шаг 4 — Откройте результат

После завершения откройте `index.html` в корне папки профиля — это главная страница дампа со ссылками на все разделы.

---

## Повторная попытка для упавших видео

Отдельный скрипт `kenk-vk-retry-videos.ps1` повторяет скачивание всех видео, которые ранее завершились с ошибкой:

```powershell
.\kenk-vk-retry-videos.ps1 -Profile "my_vk"
.\kenk-vk-retry-videos.ps1 -Profile "my_vk" -Browser "firefox"
```

Особенности:
- Сортирует очередь по дате последней попытки — самые старые попытки идут первыми
- Обновляет yt-dlp перед запуском
- Записывает дату каждой попытки (`LastChecked`) — при следующем запуске ранее обработанные видео уходят в конец очереди
- Выводит статистику базы данных после каждого сохранения: `[ 📊 N total ] [ ✅ N ok ] [ ❌ N fail ]`

---

## Отчёт по использованию видео

Скрипт `kenk-vk-video-usage.ps1` генерирует `videos-usage.html` в корне профиля — таблицу всех скачанных видео с размером файла и списком HTML-страниц из дампа, где каждое видео упоминается:

```powershell
.\kenk-vk-video-usage.ps1 -Profile "my_vk"
```

Это удобно для очистки архива: найдите большие видео, перейдите по ссылкам к исходным страницам ВКонтакте, удалите ненужные посты или сообщения — и в следующем дампе эти видео не появятся.

Отчёт также генерируется автоматически при каждом запуске основного скрипта.

---

## Дополнительные параметры

| Параметр | Описание |
|---|---|
| `-SkipPhotos` | Пропустить скачивание фотографий |
| `-SkipVideos` | Пропустить скачивание видео |
| `-RetryErrors` | Повторить попытку скачать видео, которые ранее завершились с ошибкой |
| `-Browser` | Браузер для чтения cookies при скачивании видео (по умолчанию `chrome`) |
| `-DownloadDelay` | Задержка в секундах между запросами при скачивании файлов (по умолчанию `0.4`) |
| `-PhotoLabel` | Метка раздела фотографий в дампе (если автодетект не сработал) |
| `-VideoLabel` | Метка раздела видео в дампе (если автодетект не сработал) |
| `-FileLabel` | Метка раздела файлов в дампе (если автодетект не сработал) |
| `-ForceReloadAvatars` | Сбросить кэш аватаров и скачать заново |
| `-ReportOnly` | Только сгенерировать `videos-report.html` — без скачивания и парсинга дампа |

Скрипт автоматически определяет метки типов вложений (фото/видео/файл) по содержимому дампа — это работает на любом языке интерфейса ВКонтакте. Если какой-то тип не удалось обнаружить, скрипт остановится и покажет подсказку с нужными флагами.

По умолчанию видео с ошибкой в базе **не перекачиваются** — HTML заполняется сохранённым текстом ошибки из базы. Для принудительного ретрая используйте `-RetryErrors` или отдельный скрипт `kenk-vk-retry-videos.ps1`.

Примеры:

```powershell
# Только видео, без фото
.\kenk-vk-enricher.ps1 -Profile "my_vk" -SkipPhotos

# Только фото, без видео
.\kenk-vk-enricher.ps1 -Profile "my_vk" -SkipVideos

# Использовать Firefox вместо Chrome для cookies
.\kenk-vk-enricher.ps1 -Profile "my_vk" -Browser "firefox"

# Замедлить скачивание (например, чтобы не получить бан по IP)
.\kenk-vk-enricher.ps1 -Profile "my_vk" -DownloadDelay 1.5

# Задать метки вручную (если интерфейс ВК на английском)
.\kenk-vk-enricher.ps1 -Profile "my_vk" -PhotoLabel "Photo" -VideoLabel "Video" -FileLabel "File"

# Повторный запуск — скрипт пропускает уже скачанные файлы и ошибочные
.\kenk-vk-enricher.ps1 -Profile "my_vk"

# Повторный запуск с ретраем ошибочных видео
.\kenk-vk-enricher.ps1 -Profile "my_vk" -RetryErrors

# Перегенерировать отчёт по видео без повторной обработки
.\kenk-vk-enricher.ps1 -Profile "my_vk" -ReportOnly
```

> Скрипт безопасно запускать несколько раз подряд — уже скачанные файлы пропускаются.

---

## Что скачивается и как

### Переписка (`messages/`)

- Все изображения из вложений скачиваются и сохраняются рядом с HTML-файлом
- Прикреплённые файлы (документы, архивы и т.д.) скачиваются в `files-dl/`
- Видео скачиваются через yt-dlp
- Аватары авторов сообщений кэшируются в `.data/avatars/` и вставляются в HTML
- VK-разметка вида `[id123|текст]` преобразуется в активные ссылки

### Стена (`wall/`)

- Фотографии пользователя заменяются на локальные копии
- Фотографии других пользователей и репосты из групп — скачиваются через `og:image` страницы ВКонтакте, кэшируются в `.data/external-photos/`
- Видео скачиваются через yt-dlp
- VK-разметка вида `[club123|текст]` преобразуется в активные ссылки

### Фотоальбомы (`photos/`)

- Все фотографии скачиваются в `photos-dl/<название альбома>/`
- Описания фотографий сохраняются в файлы `*.txt` рядом с изображениями
- HTML переписывается: клик по превью открывает полное разрешение с диска

### Видеоальбомы (`video/`)

- Видео скачиваются через yt-dlp

### Видео — важные детали

Перед каждым скачиванием видео скрипт:
1. Закрывает Chrome (иначе Chrome блокирует файл cookies)
2. Запускает yt-dlp, который читает cookies из закрытого браузера
3. Обновляет yt-dlp до последней версии при каждом запуске скрипта

Для каждого видео сохраняется: видеофайл (`.mkv`), превью (`.webp` или `.jpg`), метаданные (`.json`), описание (`.description`). Если видео скачать не удалось — причина записывается прямо в HTML-страницу рядом с видео.

> **Внимание:** скачивание видео может занять много времени и потребовать значительного объёма трафика и места на диске.

### Комментарии (`wall/`, `video/video-comments/`, `comments/`)

- Файлы комментариев обрабатываются по той же схеме, что и переписка: аватары и вложения
- VK-разметка вида `[id123|текст]` преобразуется в активные ссылки

### Что не обрабатывается

- Аудиозаписи — только ссылки, без скачивания
- Внешние ссылки (`Ссылка`) — остаются без изменений
- Сторис — yt-dlp не поддерживает `vk.com/story...` URL, VK перенаправляет на JS-страницу без медиа
- Лайки, закладки, сессии и прочие разделы без медиа

---

## База данных скачанных файлов

Файл `.data/files.json` — основная база данных профиля. Каждая запись содержит:

| Поле | Описание |
|---|---|
| `VKID` | Идентификатор видео в ВК (`video142509908_456239262`) |
| `MetadataID` | Идентификатор видео на хостинге (YouTube ID и т.п.) |
| `StoredVideoFileName` | Имя скачанного файла или текст ошибки |
| `StoredThumbnailFileName` | Имя файла превью |
| `YTDLPResult` | Результат: пусто — успех, `error` — ошибка |
| `LastChecked` | Дата последней попытки скачивания (`yyyy-MM-dd`) |
| `URL` | Полный URL видео в ВК |

При каждом запуске скрипт автоматически:
- Восстанавливает базу, если она была повреждена
- Устраняет дублирующиеся записи по `VKID`
- Восстанавливает `MetadataID` из `.info.json` файлов на диске, если поле пустое
- Удаляет дублирующиеся видеофайлы на диске (одно и то же видео под разными VK-ссылками), перенаправляя все записи на один файл

---

## Структура папки профиля

```
profiles/
└── my_vk/
    ├── .source/          ← исходные файлы из zip (никогда не изменяются)
    ├── .data/            ← база данных скачанных файлов
    │   ├── files.json    ← записи о скачанных/упавших видео
    │   ├── avatars/      ← кэш аватаров авторов переписки
    │   └── external-photos/ ← кэш фото из чужих постов (скачаны через og:image)
    ├── .tmp/             ← временные файлы во время работы
    ├── .logs/            ← логи запусков, сгруппированные по месяцам
    │
    ├── messages/         ← обогащённые HTML переписок
    ├── wall/             ← обогащённые HTML стены
    ├── photos/           ← обогащённые HTML фотоальбомов
    ├── video/            ← обогащённые HTML видеоальбомов
    ├── profile/          ← страницы профиля (друзья, подарки и т.д.)
    │
    ├── videos-dl/        ← скачанные видеофайлы
    ├── photos-dl/        ← скачанные фотографии по альбомам
    ├── files-dl/         ← скачанные вложенные файлы
    │
    ├── index.html        ← точка входа — открывать отсюда
    ├── style.css
    └── meta.json         ← метаданные профиля (дата инициализации, источник)
```

Папки с точкой в начале (`.source`, `.data`, `.logs`, `.tmp`) — служебные. Всё остальное — результат обработки, который можно открывать в браузере.

---

## История изменений

| Версия | Изменения |
|---|---|
| 1.1 | Первая версия |
| 1.2 | Подстановка фотографий пользователя в дамп стены |
| 1.3 | Переименован в `kenk-vk-enricher.ps1`; скачивание видео через yt-dlp для переписки, стены и видеоальбомов |
| 1.4 | Авторизация через cookies браузера; скачивание вложенных файлов |
| 1.5 | Дедупликация видео по идентификаторам |
| 2.0 | Переработана структура профиля; флаги `-SkipPhotos` / `-SkipVideos`; автообновление yt-dlp; ограничение длины имён видеофайлов; аватары авторов в переписке |
| 2.1 | Скрипт повторной попытки `kenk-vk-retry-videos.ps1`; поле `LastChecked` — очередь retry по давности попытки; авто-восстановление и дедупликация базы данных при старте; авто-удаление дублей видеофайлов на диске; двухуровневое логирование; поддержка PowerShell 5.1 |
| 2.2 | Флаг `-RetryErrors`: по умолчанию ошибочные видео пропускаются (HTML заполняется из базы), ретрай — только явно; исправлен heal базы для групповых видео (`video-NNN_NNN`); heal создаёт записи для файлов на диске без записи в базе |
| 2.3 | Обработка файлов комментариев (аватары, вложения); внешние фото на стене скачиваются через `og:image`; VK-разметка `[id\|текст]` → активные ссылки; бейдж `processed` на обработанных страницах; исправлено масштабирование превью видео |
| 2.4 | Отчёт по видео `videos-report.html` в корне профиля: статистика и полный список видео со статусом скачки; флаг `-ReportOnly` для перегенерации без обработки дампа |
| 2.5 | Отчёт по использованию видео `videos-usage.html`: размер файла и список страниц дампа где используется каждое видео; генерируется автоматически и через `kenk-vk-video-usage.ps1` |
| 2.6 | Проверка наличия файла на диске при хите в базе видео — если файл удалён, запись сбрасывается и видео перекачивается; фотоальбомы в переписке и стене подставляются как локальные ссылки, если альбом уже скачан |

---

## English

### About

VK (vk.com) data exports via [vk.com/data_protection](https://vk.com/data_protection) contain HTML pages with links to media hosted on VK's servers — not the actual files. This means the archive stops working without internet access or if VK removes the files.

**kenk-vk-enricher** parses the dump, downloads all available media files, and rewrites HTML so everything works offline from disk.

### Requirements

- Windows 10 or 11
- PowerShell 5.1 or newer
- [`yt-dlp.exe`](https://github.com/yt-dlp/yt-dlp/releases) and [`ffmpeg.exe`](https://ffmpeg.org/download.html) in the script folder
- Google Chrome installed and logged into VK (for auth-required video downloads)

### Usage

```powershell
# Initialize profile from zip
.\kenk-vk-enricher.ps1 -Init "D:\downloads\vk-export.zip"
.\kenk-vk-enricher.ps1 -Init "D:\downloads\vk-export.zip" -Profile "my_vk"

# Run enrichment (failed videos are skipped, HTML filled from DB)
.\kenk-vk-enricher.ps1 -Profile "my_vk"
.\kenk-vk-enricher.ps1 -Profile "D:\path\to\profile-folder"

# Skip photos or videos
.\kenk-vk-enricher.ps1 -Profile "my_vk" -SkipPhotos
.\kenk-vk-enricher.ps1 -Profile "my_vk" -SkipVideos

# Force retry of failed videos (main script)
.\kenk-vk-enricher.ps1 -Profile "my_vk" -RetryErrors

# Retry failed video downloads (dedicated retry script)
.\kenk-vk-retry-videos.ps1 -Profile "my_vk"
```

Open `index.html` in the profile root folder to browse the result.

### What gets processed

| Section | What happens |
|---|---|
| Messages | Images and files downloaded locally; videos downloaded via yt-dlp; sender avatars cached and embedded |
| Wall | User's own photos replaced with local copies; videos downloaded |
| Photo albums | All photos downloaded to `photos-dl/<album name>/`; descriptions saved as `.txt` |
| Video albums | Videos downloaded via yt-dlp |

**Not processed:** audio tracks, external links, stories (yt-dlp does not support `vk.com/story...` — VK redirects to a JS-rendered page with no extractable media), bookmarks.

### Changelog

| Version | Changes |
|---|---|
| 1.1 | Initial release |
| 1.2 | User photos in wall posts replaced with local copies |
| 1.3 | Renamed to `kenk-vk-enricher.ps1`; yt-dlp video downloading for messages, wall, video albums |
| 1.4 | Browser cookie auth for video; attached file downloading |
| 1.5 | Video deduplication by ID |
| 2.0 | Restructured profile layout; `-SkipPhotos` / `-SkipVideos` flags; yt-dlp auto-update; video filename length limit; sender avatars in messages |
| 2.1 | `kenk-vk-retry-videos.ps1` retry script; `LastChecked` field — retry queue sorted by oldest attempt; auto-repair and dedup of file database on startup; auto-removal of duplicate video files on disk; two-level logging; PowerShell 5.1 support |
| 2.2 | `-RetryErrors` flag: failed videos are skipped by default (HTML filled from DB), retry is explicit; fixed DB heal for group videos (`video-NNN_NNN`); heal creates DB entries for files on disk with no DB record |
| 2.3 | Comment file processing (avatars, attachments); external wall photos downloaded via `og:image`; VK markup `[id\|text]` → hyperlinks; `processed` badge on enriched pages; video thumbnail scaling fix |
| 2.4 | `videos-report.html` in profile root: stats and full per-video status table; `-ReportOnly` flag to regenerate without reprocessing |
| 2.5 | `videos-usage.html`: per-video file size and list of dump pages where each video is referenced; generated automatically and via `kenk-vk-video-usage.ps1` |
| 2.6 | Video file existence check on DB hit — if the file was deleted from disk, the DB entry is reset and the video is re-downloaded; photo album links in messages and wall are resolved to local paths when the album is already downloaded |
