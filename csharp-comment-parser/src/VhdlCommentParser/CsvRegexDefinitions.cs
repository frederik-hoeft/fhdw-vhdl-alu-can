using System.Text.RegularExpressions;

namespace VhdlCommentParser;

internal static partial class CsvRegexDefinitions
{
    [GeneratedRegex(";|,")]
    public static partial Regex GetColumnsRegex();

    [GeneratedRegex(";;|,,")]
    public static partial Regex GetEmptyColumnRegex();
}