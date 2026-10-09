# Copyright (c) 2025 ByteDance Ltd. and/or its affiliates
# SPDX-License-Identifier: MIT

"""OpenAI-compatible API client wrapper with tool integration.

This implementation uses the Chat Completions API instead of the Responses API,
because some OpenAI-compatible proxies (including the configured proxy) expose
/v1/chat/completions but do not expose /v1/responses.
"""

import json
from typing import Any, override

import openai

from trae_agent.tools.base import Tool, ToolCall, ToolResult
from trae_agent.utils.config import ModelConfig
from trae_agent.utils.llm_clients.base_client import BaseLLMClient
from trae_agent.utils.llm_clients.llm_basics import LLMMessage, LLMResponse, LLMUsage
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

        # Some reasoning models do not accept temperature.
        model_name = model_config.model.lower()

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
        """Send chat messages to OpenAI-compatible Chat Completions API."""

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
            raise RuntimeError("OpenAI-compatible API returned no choices")

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

            # Preserve the assistant tool-call message in history.
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
            prompt_tokens = getattr(response.usage, "prompt_tokens", 0) or 0
            completion_tokens = getattr(
                response.usage,
                "completion_tokens",
                0,
            ) or 0

            reasoning_tokens = 0

            completion_details = getattr(
                response.usage,
                "completion_tokens_details",
                None,
            )

            if completion_details:
                reasoning_tokens = (
                    getattr(completion_details, "reasoning_tokens", 0) or 0
                )

            prompt_details = getattr(
                response.usage,
                "prompt_tokens_details",
                None,
            )

            cached_tokens = 0

            if prompt_details:
                cached_tokens = (
                    getattr(prompt_details, "cached_tokens", 0) or 0
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
