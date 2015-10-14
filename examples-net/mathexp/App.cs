using System;
using System.Diagnostics;


static class Accessors {
	public static double GetValue(this Racr.AstNode n) {
		return n.Child<double>("value");
	}
	public static string GetName(this Racr.AstNode n) {
		return n.Child<string>("name");
	}
	public static Racr.AstNode GetExp(this Racr.AstNode n) {
		return n.Child("Exp");
	}
	public static Racr.AstNode GetA(this Racr.AstNode n) {
		return n.Child("A");
	}
	public static Racr.AstNode GetB(this Racr.AstNode n) {
		return n.Child("B");
	}
	public static Racr.AstNode GetDefs(this Racr.AstNode n) {
		return n.Child("Defs");
	}
	public static double Eval(this Racr.AstNode n) {
		return n.AttValue<double>("Eval");
	}
	public static Racr.AstNode Lookup(this Racr.AstNode n, string name) {
		return n.AttValue<Racr.AstNode>("Lookup", name);
	}
}

class App {
	public static void Main() {


		var spec = new Racr.Specification();

		spec.AstRule("Root->Def*<Defs-Exp");
		spec.AstRule("Def->name-value");
		spec.AstRule("Exp->");
		spec.AstRule("BinExp:Exp->Exp<A-Exp<B");
		spec.AstRule("AddExp:BinExp->");
		spec.AstRule("MulExp:BinExp->");
		spec.AstRule("Number:Exp->value");
		spec.AstRule("Const:Exp->name");
		spec.CompileAstSpecifications("Root");

		spec.SpecifyAttribute("Eval", "Root", "*", true, (n) =>
			n.GetExp().Eval());

		spec.SpecifyAttribute("Eval", "AddExp", "*", true, (n) =>
			n.GetA().Eval() + n.GetB().Eval());

		spec.SpecifyAttribute("Eval", "MulExp", "*", true, (n) =>
			n.GetA().Eval() * n.GetB().Eval());

		spec.SpecifyAttribute("Eval", "Number", "*", true, (n) =>
			n.GetValue());

		spec.SpecifyAttribute("Eval", "Const", "*", true, (n) =>
			n.Lookup(n.GetName()).GetValue());

		spec.SpecifyAttribute("Lookup", "Root", "*", true,
							  (Racr.AstNode n, string name) =>
			(Racr.AstNode) n.GetDefs().FindChild((i, d) =>
				((Racr.AstNode) d).GetName() == name));

		spec.CompileAgSpecifications();


		var defs = spec.CreateAstList(
				spec.CreateAst("Def", "a",  0.0),
				spec.CreateAst("Def", "b",  1.0),
				spec.CreateAst("Def", "c",  2.0),
				spec.CreateAst("Def", "d",  3.0),
				spec.CreateAst("Def", "e",  4.0),
				spec.CreateAst("Def", "f",  5.0),
				spec.CreateAst("Def", "g",  6.0),
				spec.CreateAst("Def", "h",  7.0),
				spec.CreateAst("Def", "i",  8.0),
				spec.CreateAst("Def", "j",  9.0),
				spec.CreateAst("Def", "k", 10.0),
				spec.CreateAst("Def", "l", 11.0),
				spec.CreateAst("Def", "m", 12.0),
				spec.CreateAst("Def", "n", 13.0),
				spec.CreateAst("Def", "o", 14.0),
				spec.CreateAst("Def", "p", 15.0),
				spec.CreateAst("Def", "q", 16.0),
				spec.CreateAst("Def", "r", 17.0),
				spec.CreateAst("Def", "s", 18.0),
				spec.CreateAst("Def", "t", 19.0),
				spec.CreateAst("Def", "u", 20.0),
				spec.CreateAst("Def", "v", 21.0),
				spec.CreateAst("Def", "w", 22.0),
				spec.CreateAst("Def", "x", 23.0),
				spec.CreateAst("Def", "y", 24.0),
				spec.CreateAst("Def", "z", 25.0));

		var exp = Generated.Tree(spec);

		var root = spec.CreateAst("Root", defs, exp);

		Console.WriteLine("Start");
		var watch = new Stopwatch();
		watch.Start();

		for (int i = 0; i < 1000; i++) {
			var def = defs.Child(i % 26 + 1);
			Console.WriteLine("{0}: {1}", i, root.Eval());
			def.RewriteTerminal("value", (def.Child<double>("value") + 1.0) % 26.0);
		}

		watch.Stop();
		Console.WriteLine("Time: {0}", watch.ElapsedMilliseconds * 0.001);
	}
}

