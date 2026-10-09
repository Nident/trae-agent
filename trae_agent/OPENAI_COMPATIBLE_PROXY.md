# Интеграция Trae Agent с OpenAI-compatible LLM Proxy

## Содержание

1. [Описание проблемы](#1-описание-проблемы)
2. [Что было проверено](#2-что-было-проверено)
3. [Требования](#3-требования)
4. [Конфигурация](#4-конфигурация)
5. [Проверка LLM Proxy](#5-проверка-llm-proxy)
6. [Почему штатный Trae Agent не работает](#6-почему-штатный-trae-agent-не-работает)
7. [Что нужно изменить](#7-что-нужно-изменить)
8. [Резервная копия](#8-резервная-копия)
9. [Полный исправленный openai_client.py](#9-полный-исправленный-openai_clientpy)
10. [Проверка синтаксиса](#10-проверка-синтаксиса)
11. [Запуск Trae Agent](#11-запуск-trae-agent)
12. [Проверка работы инструментов](#12-проверка-работы-инструментов)
13. [Проверка исходников](#13-проверка-исходников)
14. [Откат изменений](#14-откат-изменений)
15. [Типичные ошибки](#15-типичные-ошибки)
16. [Безопасность API-ключей](#16-безопасность-api-ключей)
17. [Что именно было исправлено](#17-что-именно-было-исправлено)
18. [Итоговая архитектура](#18-итоговая-архитектура)

---

# 1. Описание проблемы

Trae Agent изначально использует OpenAI Responses API:

```python
self.client.responses.create(...)
```

Это означает, что запрос отправляется на endpoint:

```text
/responses
```

В используемом LLM Proxy этот endpoint не поддерживается.

При запуске Trae Agent возникала ошибка:

```text
OpenAI API call failed:
Error code: 400
{
  "error": "unsupported endpoint"
}
```

При этом сам LLM Proxy и модель работают нормально.

Проверка через Chat Completions API показала:

```text
HTTP/2 200
```

и модель:

```text
qwen35-397b-a17b-fp8
```

успешно отвечает.

Таким образом, проблема заключается не в:

- API key;
- модели;
- доступности proxy;
- Python;
- Trae Agent CLI.

Проблема заключается в несовместимости используемых API endpoint'ов.

---

# 2. Что было проверено

## 2.1. Proxy доступен

Запрос:

```bash
curl -i "https://llm-proxy.t-tech.team/chat/completions"
```

вернул:

```text
HTTP/2 401
```

и:

```json
{
  "error": "no auth header"
}
```

Это означает, что endpoint существует и proxy доступен.

Ошибка была вызвана отсутствием авторизации.

---

## 2.2. Авторизация работает

После добавления API key запрос к Chat Completions API вернул:

```text
HTTP/2 200
```

---

## 2.3. Модель работает

Proxy вернул:

```json
{
  "object": "chat.completion",
  "model": "qwen35-397b-a17b-fp8"
}
```

Следовательно, модель:

```text
qwen35-397b-a17b-fp8
```

доступна.

---

## 2.4. Работает именно Chat Completions API

Успешный endpoint:

```text
/chat/completions
```

Trae Agent же изначально использовал:

```text
/responses
```

Именно поэтому возникала ошибка:

```text
unsupported endpoint
```

---

# 3. Требования

Необходимо:

- Python 3.12 или новее;
- установленный Trae Agent;
- виртуальное окружение `.venv`;
- установленный пакет `openai`;
- API key для LLM Proxy;
- доступный OpenAI-compatible endpoint;
- модель `qwen35-397b-a17b-fp8`.

Проверить Python:

```bash
python --version
```

Проверить OpenAI SDK:

```bash
python -c "import openai; print(openai.__version__)"
```

Проверить Trae Agent:

```bash
trae-cli --help
```

---

# 4. Конфигурация

Пример конфигурации:

```json
{
  "default_provider": "openai",
  "max_steps": 120,
  "model_providers": {
    "openai": {
      "api_key": "YOUR_API_KEY",
      "base_url": "https://llm-proxy.t-tech.team",
      "model": "qwen35-397b-a17b-fp8",
      "max_tokens": 16384,
      "temperature": 0.5,
      "top_p": 1,
      "max_retries": 10
    }
  }
}
```

### Важно

Не добавлять произвольно:

```text
anthropic/
```

или другие provider prefixes к имени модели.

Используемое и проверенное имя модели:

```text
qwen35-397b-a17b-fp8
```

---

## 4.1. Проверить текущий конфиг

```bash
grep -n '"default_provider"\|"base_url"\|"model"\|"api_key"' \
  /root/trae_config.json
```

Если конфигурация находится в другом месте:

```bash
find /root/trae-agent -name "trae_config.json" -o -name "*.json"
```

---

# 5. Проверка LLM Proxy

## 5.1. Проверка без API key

```bash
curl -i "https://llm-proxy.t-tech.team/chat/completions"
```

Если получаем:

```text
HTTP/2 401
```

и:

```json
{
  "error": "no auth header"
}
```

это нормально.

Это подтверждает, что endpoint доступен.

---

## 5.2. Проверка с API key

Временно установить ключ в переменную окружения:

```bash
export LLM_KEY='YOUR_API_KEY'
```

Затем:

```bash
curl -i "https://llm-proxy.t-tech.team/chat/completions" \
  -H "Authorization: Bearer $LLM_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen35-397b-a17b-fp8",
    "messages": [
      {
        "role": "user",
        "content": "SAY HELLO"
      }
    ],
    "max_tokens": 100
  }'
```

Успешный ответ должен содержать:

```text
HTTP/2 200
```

и:

```json
{
  "object": "chat.completion",
  "model": "qwen35-397b-a17b-fp8",
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "..."
      }
    }
  ]
}
```

---

# 6. Почему штатный Trae Agent не работает

В исходном:

```text
trae_agent/utils/llm_clients/openai_client.py
```

использовалось:

```python
self.client.responses.create(
```

То есть:

```text
Trae Agent
    |
    v
OpenAI Python SDK
    |
    v
Responses API
    |
    v
/responses
    |
    X
unsupported endpoint
```

Proxy предоставляет:

```text
/chat/completions
```

Поэтому правильная схема:

```text
Trae Agent
    |
    v
OpenAI Python SDK
    |
    v
Chat Completions API
    |
    v
/chat/completions
    |
    v
LLM Proxy
    |
    v
Qwen
```

---

# 7. Что нужно изменить

Необходимо изменить только:

```text
/root/trae-agent/trae_agent/utils/llm_clients/openai_client.py
```

Файлы:

```text
base_client.py
llm_basics.py
```

изменять не требуется.

Причина:

`base_client.py` задаёт общий интерфейс клиента, а `llm_basics.py` содержит внутренние структуры:

```python
LLMMessage
LLMUsage
LLMResponse
```

Нам достаточно адаптировать конкретно OpenAI client.

---

# 8. Резервная копия

Перед изменением:

```bash
cd /root/trae-agent
```

Создать backup:

```bash
cp trae_agent/utils/llm_clients/openai_client.py \
   trae_agent/utils/llm_clients/openai_client.py.bak
```

Проверить:

```bash
ls -lh trae_agent/utils/llm_clients/openai_client.py*
```

Должны существовать:

```text
openai_client.py
openai_client.py.bak
```

---

# 9. Полный исправленный openai_client.py

Файл:

```text
/root/trae-agent/trae_agent/utils/llm_clients/openai_client.py
```

заменяется полностью.

```python
# Copyright (c) 2025 ByteDance Ltd. and/or its affiliates
# SPDX-License-Identifier: MIT

"""OpenAI-compatible API client wrapper with tool integration.

This implementation uses the Chat Completions API instead of the Responses API,
because some OpenAI-compatible proxies expose /chat/completions but do not
expose /responses.
"""

import json
from typing import Any, override

import openai

from trae_agent.tools.base import Tool, ToolCall, ToolResult
from trae_agent.utils.config import ModelConfig
from trae_agent.utils.llm_clients.base_client import BaseLLMClient
from trae_agent.utils.llm_clients.llm_basics import (
    LLMMessage,
    LLMResponse,
    LLMUsage,
)
from trae_agent.utils.llm_clients.retry_utils import retry_with


class OpenAIClient(BaseLLMClient):
    """OpenAI-compatible client using the Chat Completions API."""

    def __init__(self, model_config: ModelConfig):
        super().__init__(model_config)

        self.client: openai.OpenAI = openai.OpenAI(
            api_key=self.api_key,
            base_url=self.base_url,
        )

        self.message_history: list[dict[str, Any]] = []

    @override
    def set_chat_history(self, messages: list[LLMMessage]) -> None:
        """Set the chat history."""
        self.message_history = self.parse_messages(messages)

    def _create_openai_response(
        self,
        api_call_input: list[dict[str, Any]],
        model_config: ModelConfig,
        tool_schemas: list[dict[str, Any]] | None,
    ) -> Any:
        """Create a response using the OpenAI Chat Completions API."""

        kwargs: dict[str, Any] = {
            "model": model_config.model,
            "messages": api_call_input,
            "max_tokens": model_config.max_tokens,
        }

        if tool_schemas:
            kwargs["tools"] = tool_schemas

        model_name = model_config.model.lower()

        # Некоторые reasoning-модели не поддерживают temperature.
        if (
            "o3" not in model_name
            and "o4-mini" not in model_name
            and "gpt-5" not in model_name
        ):
            kwargs["temperature"] = model_config.temperature

        if model_config.top_p is not None:
            kwargs["top_p"] = model_config.top_p

        return self.client.chat.completions.create(**kwargs)

    @override
    def chat(
        self,
        messages: list[LLMMessage],
        model_config: ModelConfig,
        tools: list[Tool] | None = None,
        reuse_history: bool = True,
    ) -> LLMResponse:
        """Send chat messages to the OpenAI-compatible API."""

        openai_messages = self.parse_messages(messages)

        if reuse_history:
            self.message_history = self.message_history + openai_messages
        else:
            self.message_history = openai_messages

        tool_schemas: list[dict[str, Any]] | None = None

        if tools:
            tool_schemas = [
                {
                    "type": "function",
                    "function": {
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.get_input_schema(),
                    },
                }
                for tool in tools
            ]

        retry_decorator = retry_with(
            func=self._create_openai_response,
            provider_name="OpenAI",
            max_retries=model_config.max_retries,
        )

        response = retry_decorator(
            self.message_history,
            model_config,
            tool_schemas,
        )

        content = ""
        tool_calls: list[ToolCall] = []

        if not response.choices:
            raise RuntimeError(
                "OpenAI-compatible API returned no choices"
            )

        choice = response.choices[0]
        message = choice.message

        if message.content:
            content = message.content

        if message.tool_calls:
            for tool_call in message.tool_calls:
                if tool_call.type != "function":
                    continue

                function = tool_call.function

                try:
                    arguments = json.loads(function.arguments)
                except (json.JSONDecodeError, TypeError):
                    arguments = {}

                call = ToolCall(
                    call_id=tool_call.id,
                    name=function.name,
                    arguments=arguments,
                    id=tool_call.id,
                )

                tool_calls.append(call)

            # Сохраняем сообщение assistant с tool_calls
            # в историю Chat Completions.
            assistant_message: dict[str, Any] = {
                "role": "assistant",
                "content": message.content,
                "tool_calls": [
                    {
                        "id": tool_call.id,
                        "type": "function",
                        "function": {
                            "name": tool_call.function.name,
                            "arguments": tool_call.function.arguments,
                        },
                    }
                    for tool_call in message.tool_calls
                    if tool_call.type == "function"
                ],
            }

            self.message_history.append(assistant_message)

        elif content:
            self.message_history.append(
                {
                    "role": "assistant",
                    "content": content,
                }
            )

        usage = None

        if response.usage:
            prompt_tokens = (
                getattr(response.usage, "prompt_tokens", 0) or 0
            )

            completion_tokens = (
                getattr(response.usage, "completion_tokens", 0) or 0
            )

            reasoning_tokens = 0

            completion_details = getattr(
                response.usage,
                "completion_tokens_details",
                None,
            )

            if completion_details:
                reasoning_tokens = (
                    getattr(
                        completion_details,
                        "reasoning_tokens",
                        0,
                    )
                    or 0
                )

            prompt_details = getattr(
                response.usage,
                "prompt_tokens_details",
                None,
            )

            cached_tokens = 0

            if prompt_details:
                cached_tokens = (
                    getattr(
                        prompt_details,
                        "cached_tokens",
                        0,
                    )
                    or 0
                )

            usage = LLMUsage(
                input_tokens=prompt_tokens,
                output_tokens=completion_tokens,
                cache_read_input_tokens=cached_tokens,
                reasoning_tokens=reasoning_tokens,
            )

        finish_reason = choice.finish_reason

        llm_response = LLMResponse(
            content=content,
            usage=usage,
            model=response.model,
            finish_reason=finish_reason,
            tool_calls=tool_calls if tool_calls else None,
        )

        if self.trajectory_recorder:
            self.trajectory_recorder.record_llm_interaction(
                messages=messages,
                response=llm_response,
                provider="openai",
                model=model_config.model,
                tools=tools,
            )

        return llm_response

    def parse_messages(
        self,
        messages: list[LLMMessage],
    ) -> list[dict[str, Any]]:
        """Convert internal messages to Chat Completions format."""

        openai_messages: list[dict[str, Any]] = []

        for msg in messages:
            if msg.tool_result:
                openai_messages.append(
                    self.parse_tool_call_result(msg.tool_result)
                )

            elif msg.tool_call:
                openai_messages.append(
                    self.parse_tool_call(msg.tool_call)
                )

            else:
                if not msg.content:
                    raise ValueError("Message content is required")

                if msg.role == "system":
                    openai_messages.append(
                        {
                            "role": "system",
                            "content": msg.content,
                        }
                    )

                elif msg.role == "user":
                    openai_messages.append(
                        {
                            "role": "user",
                            "content": msg.content,
                        }
                    )

                elif msg.role == "assistant":
                    openai_messages.append(
                        {
                            "role": "assistant",
                            "content": msg.content,
                        }
                    )

                else:
                    raise ValueError(
                        f"Invalid message role: {msg.role}"
                    )

        return openai_messages

    def parse_tool_call(
        self,
        tool_call: ToolCall,
    ) -> dict[str, Any]:
        """Convert an internal tool call to Chat Completions format."""

        return {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": tool_call.call_id,
                    "type": "function",
                    "function": {
                        "name": tool_call.name,
                        "arguments": json.dumps(
                            tool_call.arguments,
                            ensure_ascii=False,
                        ),
                    },
                }
            ],
        }

    def parse_tool_call_result(
        self,
        tool_call_result: ToolResult,
    ) -> dict[str, Any]:
        """Convert a tool result to Chat Completions format."""

        result_content = ""

        if tool_call_result.result is not None:
            result_content += str(tool_call_result.result)

        if tool_call_result.error:
            result_content += f"\nError: {tool_call_result.error}"

        result_content = result_content.strip()

        return {
            "role": "tool",
            "tool_call_id": tool_call_result.call_id,
            "content": result_content,
        }
```

---

# 10. Проверка синтаксиса

Перейти в проект:

```bash
cd /root/trae-agent
```

Активировать окружение:

```bash
source .venv/bin/activate
```

Проверить Python:

```bash
python --version
```

Проверить синтаксис:

```bash
python -m py_compile \
  trae_agent/utils/llm_clients/openai_client.py
```

Если команда ничего не вывела:

```text
```

значит синтаксис корректный.

---

# 11. Запуск Trae Agent

Теперь:

```bash
trae-cli run "SAY HELLO"
```

Ожидаем:

```text
Model Provider: openai
Model: qwen35-397b-a17b-fp8
```

Главное отличие от предыдущего запуска:

Trae Agent больше не должен вызывать:

```text
/responses
```

Он должен использовать:

```text
/chat/completions
```

Ошибка:

```text
400 unsupported endpoint
```

должна исчезнуть.

---

# 12. Проверка работы инструментов

Простой:

```bash
trae-cli run "SAY HELLO"
```

проверяет только текстовый ответ.

Для Trae Agent этого недостаточно.

Нужно проверить tool calling.

## 12.1. Тест bash

Запустить:

```bash
trae-cli run "Создай файл /tmp/trae_test.txt с текстом HELLO и проверь его содержимое."
```

Ожидаемый сценарий:

```text
Trae Agent
    |
    v
Qwen
    |
    | tool_calls
    v
bash
    |
    v
/tmp/trae_test.txt
    |
    v
tool result
    |
    v
Qwen
    |
    v
task_done
```

После завершения:

```bash
cat /tmp/trae_test.txt
```

Ожидаемый результат:

```text
HELLO
```

---

# 13. Проверка исходников

Проверить, что Responses API больше не используется:

```bash
grep -n "responses.create" \
  /root/trae-agent/trae_agent/utils/llm_clients/openai_client.py
```

Ожидается:

```text
```

то есть отсутствие вывода.

Проверить Chat Completions:

```bash
grep -n "chat.completions.create" \
  /root/trae-agent/trae_agent/utils/llm_clients/openai_client.py
```

Должно быть:

```text
return self.client.chat.completions.create(**kwargs)
```

---

## 13.1. Проверить tool calls

```bash
grep -n "tool_calls" \
  /root/trae-agent/trae_agent/utils/llm_clients/openai_client.py
```

Должно быть несколько совпадений.

Проверить tool result:

```bash
grep -n '"role": "tool"' \
  /root/trae-agent/trae_agent/utils/llm_clients/openai_client.py
```

Должно присутствовать:

```python
"role": "tool",
```

---

# 14. Откат изменений

Если понадобится вернуть оригинальный клиент:

```bash
cd /root/trae-agent
```

Восстановить backup:

```bash
cp trae_agent/utils/llm_clients/openai_client.py.bak \
   trae_agent/utils/llm_clients/openai_client.py
```

Проверить:

```bash
python -m py_compile \
  trae_agent/utils/llm_clients/openai_client.py
```

---

# 15. Типичные ошибки

## 15.1. `unsupported endpoint`

Ошибка:

```text
400 {"error":"unsupported endpoint"}
```

Причина:

Trae Agent использует:

```text
/responses
```

а proxy поддерживает:

```text
/chat/completions
```

Проверить:

```bash
grep -n "responses.create" \
  trae_agent/utils/llm_clients/openai_client.py
```

В исправленной версии совпадений быть не должно.

---

## 15.2. `no auth header`

Ошибка:

```text
401 {"error":"no auth header"}
```

Причина:

В запросе нет заголовка:

```text
Authorization: Bearer ...
```

Проверка:

```bash
export LLM_KEY='YOUR_API_KEY'
```

Затем:

```bash
curl -i "https://llm-proxy.t-tech.team/chat/completions" \
  -H "Authorization: Bearer $LLM_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen35-397b-a17b-fp8",
    "messages": [
      {
        "role": "user",
        "content": "SAY HELLO"
      }
    ],
    "max_tokens": 100
  }'
```

---

## 15.3. `model not found`

Ошибка:

```text
400 {"error":"model not found"}
```

Проверить модель:

```text
qwen35-397b-a17b-fp8
```

Не использовать:

```text
anthropic/qwen35-397b-a17b-fp8
```

или другие случайные prefixes.

Модель была успешно проверена напрямую через proxy:

```text
qwen35-397b-a17b-fp8
```

---

## 15.4. `404 Not Found`

Возможно, proxy использует `/v1`.

Проверить:

```bash
curl -i \
  "https://llm-proxy.t-tech.team/chat/completions"
```

и:

```bash
curl -i \
  "https://llm-proxy.t-tech.team/v1/chat/completions"
```

Если один endpoint возвращает `401`, а другой `404`, endpoint с `401` является правильным маршрутом с точки зрения доступности.

---

## 15.5. Обычный запрос работает, но `bash` не работает

Это означает, что базовая связь:

```text
Trae Agent → Proxy → Qwen
```

работает, но есть проблема с function/tool calling.

Нужно проверить, возвращает ли модель:

```json
"tool_calls": [
  {
    "id": "call_...",
    "type": "function",
    "function": {
      "name": "bash",
      "arguments": "..."
    }
  }
]
```

Если модель возвращает только обычный текст, возможны следующие причины:

- модель не поддерживает function calling;
- proxy не передаёт `tools`;
- proxy меняет формат tool calls;
- модель не следует переданной tool schema;
- текущая версия Trae Agent ожидает другой формат.

---

# 16. Безопасность API-ключей

API key нельзя помещать в Git.

Нельзя коммитить:

```json
{
  "api_key": "REAL_SECRET"
}
```

Не следует публиковать API key в:

- GitHub;
- GitLab;
- README;
- issue tracker;
- Discord;
- Telegram;
- чатах;
- скриншотах;
- логах.

Для временной проверки можно использовать:

```bash
export LLM_KEY='YOUR_API_KEY'
```

Если настоящий API key уже был опубликован, его следует отозвать и создать новый.

---

# 17. Что именно было исправлено

## До изменения

Trae Agent:

```text
Trae Agent
    |
    v
OpenAIClient
    |
    v
client.responses.create()
    |
    v
Responses API
    |
    v
/responses
    |
    X
400 unsupported endpoint
```

---

## После изменения

Trae Agent:

```text
Trae Agent
    |
    v
OpenAIClient
    |
    v
client.chat.completions.create()
    |
    v
Chat Completions API
    |
    v
/chat/completions
    |
    v
LLM Proxy
    |
    v
qwen35-397b-a17b-fp8
    |
    v
HTTP 200
```

---

## Поддержка инструментов

Адаптер преобразует внутренние Trae Agent tools:

```text
bash
task_done
```

в формат Chat Completions:

```json
{
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "bash",
        "description": "...",
        "parameters": {}
      }
    }
  ]
}
```

Ответ модели:

```json
{
  "tool_calls": [
    {
      "id": "call_123",
      "type": "function",
      "function": {
        "name": "bash",
        "arguments": "{\"command\":\"...\"}"
      }
    }
  ]
}
```

преобразуется обратно во внутренний:

```python
ToolCall(
    call_id=...,
    name=...,
    arguments=...,
    id=...,
)
```

Результат выполнения инструмента отправляется модели как:

```json
{
  "role": "tool",
  "tool_call_id": "call_123",
  "content": "..."
}
```

Таким образом, сохраняется основной agent loop:

```text
модель
  ↓
tool call
  ↓
Trae Agent
  ↓
инструмент
  ↓
tool result
  ↓
модель
  ↓
следующий шаг
```

---

# 18. Итоговая архитектура

Финальная архитектура:

```text
                    ┌───────────────────────┐
                    │      Trae Agent       │
                    └───────────┬───────────┘
                                │
                                v
                    ┌───────────────────────┐
                    │     OpenAIClient      │
                    │                       │
                    │ Chat Completions API  │
                    └───────────┬───────────┘
                                │
                                │ POST
                                │ /chat/completions
                                v
                    ┌───────────────────────┐
                    │       LLM Proxy       │
                    │                       │
                    │ llm-proxy.t-tech.team │
                    └───────────┬───────────┘
                                │
                                v
                    ┌───────────────────────┐
                    │ qwen35-397b-a17b-fp8 │
                    └───────────┬───────────┘
                                │
                   ┌────────────┴────────────┐
                   │                         │
                   v                         v
             обычный ответ              tool_calls
                                             │
                                             v
                                      ┌─────────────┐
                                      │ Trae Tools  │
                                      │             │
                                      │ bash        │
                                      │ task_done   │
                                      └──────┬──────┘
                                             │
                                             v
                                        tool result
                                             │
                                             v
                                           Qwen
```

## Ключевое решение

Для данного proxy используется:

```text
/chat/completions
```

а не:

```text
/responses
```

Модель:

```text
qwen35-397b-a17b-fp8
```

проверена напрямую через proxy и отвечает успешно.

Изменение необходимо только в:

```text
trae_agent/utils/llm_clients/openai_client.py
```

`base_client.py` и `llm_basics.py` менять не требуется.

После обновления Trae Agent необходимо обязательно проверить не только:

```bash
trae-cli run "SAY HELLO"
```

но и реальный вызов инструмента `bash`, поскольку именно tool calling является критической частью работы агентного режима.