import 'package:langchain_anthropic/langchain_anthropic.dart';
import 'package:langchain_core/tools.dart';
import 'package:langchain_google/langchain_google.dart';
import 'package:langchain_openai/langchain_openai.dart';
import 'package:test/test.dart';

import 'package:wenzagent/src/agent/adapter/chat_model_factory.dart';
import 'package:wenzagent/src/agent/adapter/provider_config.dart';

void main() {
  group('ChatModelFactory.create', () {
    test('openai 返回 ChatOpenAI 实例', () {
      final model = ChatModelFactory.create(
        const ProviderConfig(
          provider: LLMProvider.openai,
          model: 'gpt-4o',
          apiKey: 'test-key',
        ),
      );
      expect(model, isA<ChatOpenAI>());
    });

    test('anthropic 返回 ChatAnthropic 实例', () {
      final model = ChatModelFactory.create(
        const ProviderConfig(
          provider: LLMProvider.anthropic,
          model: 'claude-sonnet-4-20250514',
          apiKey: 'test-key',
        ),
      );
      expect(model, isA<ChatAnthropic>());
    });

    test('google 返回 ChatGoogleGenerativeAI 实例', () {
      final model = ChatModelFactory.create(
        const ProviderConfig(
          provider: LLMProvider.google,
          model: 'gemini-2.5-pro',
          apiKey: 'test-key',
        ),
      );
      expect(model, isA<ChatGoogleGenerativeAI>());
    });

    test('ollama 返回 ChatOpenAI 实例（OpenAI 兼容 API）', () {
      final model = ChatModelFactory.create(
        const ProviderConfig(provider: LLMProvider.ollama, model: 'llama3'),
      );
      expect(model, isA<ChatOpenAI>());
    });

    test('openai 携带自定义 baseUrl', () {
      final model = ChatModelFactory.create(
        const ProviderConfig(
          provider: LLMProvider.openai,
          model: 'gpt-4o',
          apiKey: 'test-key',
          baseUrl: 'https://custom.openai.com/v1',
        ),
      );
      expect(model, isA<ChatOpenAI>());
    });

    test('anthropic 无 apiKey 时 validate 抛出异常', () {
      expect(
        () => ChatModelFactory.create(
          const ProviderConfig(
            provider: LLMProvider.anthropic,
            model: 'claude-sonnet-4-20250514',
          ),
        ),
        throwsArgumentError,
      );
    });

    test('google 无 apiKey 时 validate 抛出异常', () {
      expect(
        () => ChatModelFactory.create(
          const ProviderConfig(
            provider: LLMProvider.google,
            model: 'gemini-2.5-pro',
          ),
        ),
        throwsArgumentError,
      );
    });

    test('所有提供商都支持 LLMOptions 参数', () {
      const options = LLMOptions(
        temperature: 0.5,
        maxTokens: 1024,
        topP: 0.9,
        stop: ['STOP'],
      );

      // OpenAI
      final openai = ChatModelFactory.create(
        const ProviderConfig(
          provider: LLMProvider.openai,
          model: 'gpt-4o',
          apiKey: 'test-key',
          options: options,
        ),
      );
      expect(openai, isA<ChatOpenAI>());

      // Anthropic
      final anthropic = ChatModelFactory.create(
        const ProviderConfig(
          provider: LLMProvider.anthropic,
          model: 'claude-sonnet-4-20250514',
          apiKey: 'test-key',
          options: options,
        ),
      );
      expect(anthropic, isA<ChatAnthropic>());

      // Google
      final google = ChatModelFactory.create(
        const ProviderConfig(
          provider: LLMProvider.google,
          model: 'gemini-2.5-pro',
          apiKey: 'test-key',
          options: options,
        ),
      );
      expect(google, isA<ChatGoogleGenerativeAI>());

      // Ollama
      final ollama = ChatModelFactory.create(
        const ProviderConfig(
          provider: LLMProvider.ollama,
          model: 'llama3',
          options: options,
        ),
      );
      expect(ollama, isA<ChatOpenAI>());
    });
  });

  group('ChatModelFactory.createToolOptions', () {
    final testToolSpecs = [
      ToolSpec(
        name: 'test_tool',
        description: 'A test tool',
        inputJsonSchema: {
          'type': 'object',
          'properties': {
            'input': {'type': 'string', 'description': 'Test input'},
          },
          'required': ['input'],
        },
      ),
    ];

    test('openai 返回 ChatOpenAIOptions', () {
      final options = ChatModelFactory.createToolOptions(
        LLMProvider.openai,
        testToolSpecs,
      );
      expect(options, isA<ChatOpenAIOptions>());
    });

    test('anthropic 返回 ChatAnthropicOptions', () {
      final options = ChatModelFactory.createToolOptions(
        LLMProvider.anthropic,
        testToolSpecs,
      );
      expect(options, isA<ChatAnthropicOptions>());
    });

    test('google 返回 ChatGoogleGenerativeAIOptions', () {
      final options = ChatModelFactory.createToolOptions(
        LLMProvider.google,
        testToolSpecs,
      );
      expect(options, isA<ChatGoogleGenerativeAIOptions>());
    });

    test('ollama 返回 ChatOpenAIOptions（OpenAI 兼容）', () {
      final options = ChatModelFactory.createToolOptions(
        LLMProvider.ollama,
        testToolSpecs,
      );
      expect(options, isA<ChatOpenAIOptions>());
    });

    test('toolSpecs 为 null 时返回 null', () {
      final options = ChatModelFactory.createToolOptions(
        LLMProvider.openai,
        null,
      );
      expect(options, isNull);
    });

    test('toolSpecs 为空列表时返回 null', () {
      final options = ChatModelFactory.createToolOptions(
        LLMProvider.openai,
        [],
      );
      expect(options, isNull);
    });
  });
}
