namespace VhdlCommentParser.Formatting.Handlers;

internal partial record class NopFormatHandler() : IFormatHandler
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
