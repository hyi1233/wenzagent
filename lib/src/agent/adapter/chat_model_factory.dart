import 'package:langchain_core/chat_models.dart';
import 'package:langchain_openai/langchain_openai.dart';

import 'provider_config.dart';

/// ChatModel 工厂类
///
/// 根据配置创建对应的 LLM ChatModel 实例
class ChatModelFactory {
  /// 创建 ChatModel
  static BaseChatModel create(ProviderConfig config) {
    config.validate();

    switch (config.provider) {
      case LLMProvider.openai:
        return _createOpenAI(config);

      case LLMProvider.anthropic:
        throw UnimplementedError(
          'Anthropic support requires langchain_anthropic package. '
          'Add it to pubspec.yaml and implement _createAnthropic().',
        );

      case LLMProvider.google:
        throw UnimplementedError(
          'Google AI support requires langchain_google package. '
          'Add it to pubspec.yaml and implement _createGoogle().',
        );

      case LLMProvider.ollama:
        return _createOllama(config);
    }
  }

  /// 创建 OpenAI ChatModel
  static ChatOpenAI _createOpenAI(ProviderConfig config) {
    return ChatOpenAI(
      apiKey: config.apiKey,
      baseUrl: config.baseUrl ?? 'https://api.openai.com/v1',
      defaultOptions: ChatOpenAIOptions(
        model: config.model,
        temperature: config.options.temperature,
        maxTokens: config.options.maxTokens,
        topP: config.options.topP,
        stop: config.options.stop,
      ),
    );
  }

  /// 创建 Ollama ChatModel (本地模型)
  static ChatOpenAI _createOllama(ProviderConfig config) {
    // Ollama 使用 OpenAI 兼容的 API
    final baseUrl = config.baseUrl ?? 'http://localhost:11434/v1';

    return ChatOpenAI(
      baseUrl: baseUrl,
      defaultOptions: ChatOpenAIOptions(
        model: config.model,
        temperature: config.options.temperature,
        maxTokens: config.options.maxTokens,
        topP: config.options.topP,
        stop: config.options.stop,
      ),
    );
  }

  // 可以扩展支持更多提供商:
  //
  // static ChatAnthropic _createAnthropic(ProviderConfig config) {
  //   return ChatAnthropic(
  //     apiKey: config.apiKey,
  //     defaultOptions: ChatAnthropicOptions(
  //       model: config.model,
  //       temperature: config.options.temperature,
  //       maxTokens: config.options.maxTokens,
  //     ),
  //   );
  // }
  //
  // static ChatGoogleGenerativeAI _createGoogle(ProviderConfig config) {
  //   return ChatGoogleGenerativeAI(
  //     apiKey: config.apiKey,
  //     defaultOptions: ChatGoogleGenerativeAIOptions(
  //       model: config.model,
  //       temperature: config.options.temperature,
  //       maxOutputTokens: config.options.maxTokens,
  //     ),
  //   );
  // }
}
