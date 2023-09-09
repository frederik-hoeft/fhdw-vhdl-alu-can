namespace VhdlCommentParser.Formatting;

public interface IFormatter
{
    string Format(string cellValue);
}

public interface IFormatHandler : IFormatter
{
    static abstract bool TryCreateFor(string format, out IFormatHandler? handler);
}

public interface IFormatHandlerChain
{
    bool TryHandle(string format, out IFormatHandler? handler);
}

public delegate bool HandlerFactoryPointer(string format, out IFormatHandler? handlerFactory);