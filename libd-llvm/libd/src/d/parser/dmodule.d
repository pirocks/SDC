module d.parser.dmodule;

import d.ast.declaration;
import d.ast.dmodule;

import d.parser.base;
import d.parser.declaration;

import sdc.tokenstream;

/**
 * Parse a whole module.
 * This is the regular entry point in the parser
 */
auto parseModule(TokenRange)(ref TokenRange trange) if(isTokenRange!TokenRange) {
	trange.match(TokenType.Begin);
	Location location = trange.front.location;
	
	ModuleDeclaration moduleDeclaration;
	if(trange.front.type == TokenType.Module) {
		moduleDeclaration = trange.parseModuleDeclaration();
	} else {
		// TODO: compute a correct declaration according to the filename.
		moduleDeclaration = new ModuleDeclaration(location, "", [""]);
	}
	
	Declaration[] declarations;
	while(trange.front.type != TokenType.End) {
		declarations ~= trange.parseDeclaration();
	}
	
	location.spanTo(trange.front.location);
	
	return new Module(location, moduleDeclaration, declarations);
}

private auto parseModuleDeclaration(TokenRange)(ref TokenRange trange) {
	Location location = trange.front.location;
	trange.match(TokenType.Module);
	
	string[] packages;
	string name = trange.front.value;
	trange.match(TokenType.Identifier);
	while(trange.front.type == TokenType.Dot) {
		trange.popFront();
		packages ~= name;
		name = trange.front.value;
		trange.match(TokenType.Identifier);
	}
	
	location.spanTo(trange.front.location);
	trange.match(TokenType.Semicolon);
	
	return new ModuleDeclaration(location, name, packages);
}

