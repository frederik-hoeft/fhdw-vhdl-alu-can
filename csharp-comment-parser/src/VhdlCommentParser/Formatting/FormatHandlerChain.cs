using System.Diagnostics.CodeAnalysis;

namespace VhdlCommentParser.Formatting;

using static CsvRegexDefinitions;

partial class FormatHandlerChain : IFormatHandlerChain
{
    private readonly List<HandlerFactoryPointer> _handlerFactories = new();

    public FormatHandlerChain AddHandler<T>() where T : IFormatHandler
    {
        _handlerFactories.Add(T.TryCreateFor);
        return this;
    }

    private IFormatter[]? formatters;

    public FormatHandlerChain InitFrom(string[] headerLine)
    {
        formatters ??= new IFormatter[headerLine.Length];
        for (int i = 0; i < headerLine.Length; i++)
        {
            if (TryHandle(headerLine[i], out IFormatHandler? handler))
            {
                formatters[i] = handler;
            }
            else
            {
                throw new InvalidOperationException("RIP");
            }
        }
        return this;
    }

    public (string[] Inputs, string[] Expected) FormatLine(string line)
    {
        string[] data = GetEmptyColumnRegex().Split(line);
        if (data.Length != 2)
        {
            throw new FormatException("Could not detect input and output sections. Please provide input and output data separated by an empty column.");
        }
        string inputRaw = data[0];
        string expectedRaw = data[1];

        List<string> inputWordsOriginal = GetColumnsRegex().Split(inputRaw).Skip(1).ToList();
        string[] inputs = new string[inputWordsOriginal.Count];
        for (int i = 0; i < inputWordsOriginal.Count; i++)
        {
            inputs[i] = formatters![i].Format(inputWordsOriginal[i].Trim('\"'));
        }
        List<string> expectedWordsOriginal = GetColumnsRegex().Split(expectedRaw).ToList();
        string[] expected = new string[expectedWordsOriginal.Count];
        for (int i = 0; i < expectedWordsOriginal.Count; i++)
        {
            expected[i] = formatters![i + 1 + inputs.Length].Format(expectedWordsOriginal[i].Trim('\"'));
        }
        return (inputs, expected);
    }

    public bool TryHandle(string format, [NotNullWhen(true)] out IFormatHandler? handler)
    {
        foreach (HandlerFactoryPointer factory in _handlerFactories)
        {
            if (factory.Invoke(format, out handler!))
            {
                return true;
            }
        }
        handler = null;
        return false;
    }
}
