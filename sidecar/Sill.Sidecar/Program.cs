using System.Text;
using Sill.Sidecar;

// Standard output is the protocol and nothing else; anything else the sidecar has to say goes to standard error.
TextWriter protocol = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = false };
Console.SetOut(Console.Error);
using TextReader input = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
new Server(protocol).Run(input);
