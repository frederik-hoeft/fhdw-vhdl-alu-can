//#define METASTABILITY

using System.Diagnostics.CodeAnalysis;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

using static RegexThings;

// Requires:
// -> Csv file as input with the first line and first column being used for comments
// + the second line being used for word width
// + an input data section beginning at line 3 column 2
// + an output data section that is separated from the input section by an empty column
// Functionality:
// -> Converts the csv file into two txt files
// + the first txt file contains the data from the input section of the original csv file
// + the second txt file contains the data from the output section of the original csv 

if (args.Length is 0 or > 1)
{
    Console.WriteLine("Usage: ./VhdlCommentParser.exe <file>");
    return;
}

string[] lines = File.ReadAllLines(args[0]);

string inputFileName = args[0].Replace(".csv", string.Empty) + "-inputs.txt";
if (File.Exists(inputFileName))
{
    File.Delete(inputFileName);
}
using FileStream inputStream = File.OpenWrite(inputFileName);
using StreamWriter inputWriter = new(inputStream);

string expectedFileName = args[0].Replace(".csv", string.Empty) + "-expected.txt";
if (File.Exists(expectedFileName))
{
    File.Delete(expectedFileName);
}
using FileStream expectedStream = File.OpenWrite(expectedFileName);
using StreamWriter expectedWriter = new(expectedStream);

string[] columnDefinitions = GetColumnsRegex().Split(lines[0]).Skip(1).ToArray();

// if something is written in line 2 we expect it to be the word width of the column
// and that basically means that cell contents of the column are not binary digits
FormatHandlerChain chain = new FormatHandlerChain()
    .AddHandler<DecimalFormatHandler>()
    .AddHandler<HexFormatHandler>()
    .AddHandler<BinaryFormatHandler>()
    .AddHandler<LutFormatHandler>()
    .AddHandler<PrefixFormatHandler>()
    .AddHandler<NopFormatHandler>()
    .InitFrom(columnDefinitions);

// ignore the first line when copying the content to a txt file
for (int i = 2; i < lines.Length; i++)
{
    (string[] inputs, string[] expected) = chain.FormatLine(lines[i]);
    
    // remove the first column of each line (first column is used for comments or similar)
    string processedInputWords = string.Join(' ', inputs);
    inputWriter.Write(processedInputWords);
    inputWriter.WriteLine();

    if (i == lines.Length - 1)
    {
#if METASTABILITY
        // add more (basically dummy) inputs to the end while waiting for
        // input to output delay to complete tests
        // metastability shift (2 FFs)
        for (int j = 0; j < 2; j++)
        {
            inputWriter.Write(processedInputWords);
            inputWriter.WriteLine();
        }
#endif
        // base delay
        inputWriter.Write(processedInputWords);
    }

    string processedExpectedWords = string.Join(' ', expected);
    for (int j = 0; i == 2 &&
#if METASTABILITY
        j < 3;
#else
        j < 1;
#endif
        j++)
    {
        // add more (basically dummy) outputs to the start while waiting for
        // input to output delay to start tests
        // metastability shift (2 FFs) + base delay
        expectedWriter.Write(AsDontCareLine(expected));
        expectedWriter.WriteLine();
    }
    expectedWriter.Write(processedExpectedWords);
    if (i < lines.Length - 1)
    {
        expectedWriter.WriteLine();
    }
}

static string AsDontCareLine(IReadOnlyCollection<string> words)
{
    List<string> output = new();
    foreach (string word in words)
    {
        output.Add(new string('-', word.Length));
    }
    return string.Join(' ', output);
}

interface IFormatHandlerChain
{
    bool TryHandle(string format, out IFormatHandler? handler);
}

interface IFormatter
{
    string Format(string cellValue);
}

interface IFormatHandler : IFormatter
{
    static abstract bool TryCreateFor(string format, out IFormatHandler? handler);
}

delegate bool HandlerFactoryPointer(string format, out IFormatHandler? handler);

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
        for(int i = 0; i < expectedWordsOriginal.Count; i++)
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

partial record class DecimalFormatHandler(int Length, uint Mask) : IFormatHandler
{
    public static bool TryCreateFor(string format, out IFormatHandler? handler)
    {
        // FORMAT::base_10:<length>
        Match match = FormatRegex().Match(format);
        if (match.Success)
        {
            int length = Convert.ToInt32(match.Groups["length"].Value);
            uint mask = (1u << length) - 1;
            handler = new DecimalFormatHandler(length, mask);
            return true;
        }
        handler = null;
        return false;
    }

    public string Format(string cellValue) => 
        cellValue.Equals("X") 
            ? new string('-', Length) 
            : Convert.ToString(((uint)Convert.ToInt32(cellValue)) & Mask, 2).PadLeft(Length, '0');

    [GeneratedRegex("F::base_10:(?<length>[0-9]+)")]
    private static partial Regex FormatRegex();
}

partial record class NopFormatHandler() : IFormatHandler
{
    public static bool TryCreateFor(string format, out IFormatHandler? handler)
    {
        handler = new NopFormatHandler();
        return true;
    }

    public string Format(string cellValue) => cellValue.Equals("X")
        ? "-"
        : cellValue;
}

partial record class LutFormatHandler(int Length, IReadOnlyDictionary<string, string> LookupTable) : IFormatHandler
{
    public static bool TryCreateFor(string format, out IFormatHandler? handler)
    {
        // F::lut:<length>-><filename>.json
        Match match = FormatRegex().Match(format);
        if (match.Success)
        {
            int length = Convert.ToInt32(match.Groups["length"].Value);
            string file = match.Groups["file"].Value;
            using Stream stream = File.OpenRead(file);
            Dictionary<string, string> lut = JsonSerializer.Deserialize<Dictionary<string, string>>(stream)
                ?? throw new FormatException("Unable to deserialize lookup table!");

            handler = new LutFormatHandler(length, lut);
            return true;
        }
        handler = null;
        return false;
    }

    public string Format(string cellValue) =>
        cellValue.Equals("X")
            ? new string('-', Length)
            : LookupTable[cellValue];

    [GeneratedRegex("F::lut:(?<length>[0-9]+)->(?<file>.+?\\.json)")]
    private static partial Regex FormatRegex();
}

partial record class HexFormatHandler(int Length) : IFormatHandler
{
    public static bool TryCreateFor(string format, out IFormatHandler? handler)
    {
        // F::base_16:<length>
        Match match = FormatRegex().Match(format);
        if (match.Success)
        {
            int length = Convert.ToInt32(match.Groups["length"].Value);
            handler = new HexFormatHandler(length);
            return true;
        }
        handler = null;
        return false;
    }

    public string Format(string cellValue) => 
        cellValue.Equals("X")
            ? new string('-', Length) 
            : Convert.ToString(int.Parse(cellValue, NumberStyles.HexNumber), 2).PadLeft(Length, '0');

    [GeneratedRegex("F::base_16:(?<length>[0-9]+)")]
    private static partial Regex FormatRegex();
}

partial record class PrefixFormatHandler(int Length, uint Mask) : IFormatHandler
{
    public static bool TryCreateFor(string format, out IFormatHandler? handler)
    {
        // F::prefix:<length>
        Match match = FormatRegex().Match(format);
        if (match.Success)
        {
            int length = Convert.ToInt32(match.Groups["length"].Value);
            uint mask = (1u << length) - 1;
            handler = new PrefixFormatHandler(length, mask);
            return true;
        }
        handler = null;
        return false;
    }

    public string Format(string cellValue) => cellValue switch
    {
        "X" => new string('-', Length),
        ['0', 'x', ..] => Convert.ToString(int.Parse(cellValue[2..], NumberStyles.HexNumber), 2).PadLeft(Length, '0'),
        ['0', 'b', ..] => cellValue[2..].PadLeft(Length, '0'),
        _ => Convert.ToString(((uint)Convert.ToInt32(cellValue)) & Mask, 2).PadLeft(Length, '0')
    };

    [GeneratedRegex("F::prefix:(?<length>[0-9]+)")]
    private static partial Regex FormatRegex();
}

partial record class BinaryFormatHandler(int Length) : IFormatHandler
{
    public static bool TryCreateFor(string format, out IFormatHandler? handler)
    {
        // F::base_2:<length>
        Match match = FormatRegex().Match(format);
        if (match.Success)
        {
            int length = Convert.ToInt32(match.Groups["length"].Value);
            handler = new BinaryFormatHandler(length);
            return true;
        }
        handler = null;
        return false;
    }

    public string Format(string cellValue) =>
        cellValue.Equals("X")
            ? new string('-', Length)
            : cellValue;

    [GeneratedRegex("F::base_2:(?<length>[0-9]+)")]
    private static partial Regex FormatRegex();
}

static partial class RegexThings
{
    [GeneratedRegex(";|,")]
    public static partial Regex GetColumnsRegex();

    [GeneratedRegex(";;|,,")]
    public static partial Regex GetEmptyColumnRegex();
}

partial class Conversions
{
    /// <summary>
    /// Convert non binary numbers to binary.
    /// </summary>
    /// <param name="toBeChecked">The numbers as strings that may need to be converted to binary.</param>
    /// <returns>A new list full of binary digits.</returns>
    public static List<string> DoConversions(List<string> toBeChecked)
    {
        List<string> output = new();
        // check if any conversions need to be made before writing the data to the new file
        foreach (string word in toBeChecked)
        {
            if (word.EndsWith('d'))
            {
                // convert decimal number into binary digits
                int intWord = Convert.ToInt32(word[..^1]);
                string binaryWord = Convert.ToString(intWord, 2);

                Console.WriteLine($"Found: '{word}' -> Result: '{binaryWord}'");

                foreach (char binaryDigit in binaryWord)
                {
                    output.Add(binaryDigit.ToString());
                }
            }
            else
            {
                output.Add(word);
            }
        }
        return output;
    }
}