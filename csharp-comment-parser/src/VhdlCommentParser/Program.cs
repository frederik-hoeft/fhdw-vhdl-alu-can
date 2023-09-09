//#define METASTABILITY

using VhdlCommentParser;
using VhdlCommentParser.Formatting;
using VhdlCommentParser.Formatting.Handlers;
using static VhdlCommentParser.CsvRegexDefinitions;

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