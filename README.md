# Hermes Agent на Infrlo

Деплой дашборда Hermes Agent (NousResearch/hermes-agent, v2026.9.24) как
обычного Python-приложения. Docker на Infrlo не поддерживается, поэтому
схема такая: editable-установка из GitHub (`pip install -e`, обычный
wheel-билд hermes блокирует setup.py) + запуск `hermes dashboard`
с предсобранным веб-интерфейсом (`web_dist/`).

## Файлы

- `start.sh` — команда запуска: `hermes dashboard --no-open --skip-build --host 0.0.0.0 --port $PORT`
- `web_dist/` — предсобранный фронтенд дашборда (собран локально через `npm run build` в `web/`,
  чтобы на платформе не нужен был Node)

## Как задеплоить

1. Создай **публичный** GitHub-репозиторий и загрузи в него все файлы из этой папки
   (start.sh, web_dist/).
2. В дашборде Infrlo: Deploy → **From Public URL** → вставь URL репозитория, ветка `main`.
3. Build Config:
   - Build command:
     `pip install -e "git+https://github.com/NousResearch/hermes-agent.git@v2026.9.24#egg=hermes-agent[web]"`
   - Run command: `sh start.sh`
4. Нажми Deploy.

## После деплоя

В настройках приложения задай переменные окружения:

- `OPENROUTER_API_KEY` — твой ключ (или ключ другого провайдера: `OPENAI_API_KEY` и т.д.)
- `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` — пароль для входа в дашборд
  (логин по умолчанию `admin`, меняется через `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`).
  Если пароль не задан — скрипт сгенерирует случайный и напечатает его в лог деплоя.

Открой публичный URL приложения, войди под admin/пароль, выбери модель в настройках дашборда.
