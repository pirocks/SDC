module d.semantic.symbol;

import d.semantic.caster;
import d.semantic.declaration;
import d.semantic.identifier;
import d.semantic.semantic;

import d.ast.base;
import d.ast.declaration;
import d.ast.expression;
import d.ast.identifier;
import d.ast.type;

import d.ir.dscope;
import d.ir.expression;
import d.ir.symbol;
import d.ir.type;

import std.algorithm;
import std.array;
import std.conv;

// TODO: change ast to allow any statement as function body, then remove that import.
import d.ast.statement;

alias BinaryExpression = d.ir.expression.BinaryExpression;

alias PointerType = d.ir.type.PointerType;
alias FunctionType = d.ir.type.FunctionType;

final class SymbolVisitor {
	private SemanticPass pass;
	alias pass this;
	
	alias SemanticPass.Step Step;
	
	this(SemanticPass pass) {
		this.pass = pass;
	}
	
	Symbol visit(Declaration d, Symbol s) {
		return this.dispatch(d, s);
	}
	
	Symbol visit(Symbol s) {
		return this.dispatch(s);
	}
	
	Symbol visit(Declaration d, Function f) {
		auto fd = cast(FunctionDeclaration) d;
		assert(fd);
		
		// XXX: maybe monad ?
		auto params = f.params = fd.params.map!(p => new Parameter(p.location, pass.visit(p.type), p.name, p.value?(pass.visit(p.value)):null)).array();
		
		// Prepare statement visitor for return type.
		auto oldReturnType = returnType;
		auto oldManglePrefix = manglePrefix;
		scope(exit) {
			manglePrefix = oldManglePrefix;
			returnType = oldReturnType;
		}
		
		manglePrefix = manglePrefix ~ to!string(f.name.length) ~ f.name;
		auto isAuto = typeid({ return fd.returnType.type; }()) is typeid(AutoType);
		
		returnType = isAuto ? ParamType(getBuiltin(TypeKind.None), false) : pass.visit(fd.returnType);
		
		// Compute return type.
		if(!isAuto) {
			// If it isn't a static method, add this.
			if(!f.isStatic) {
				assert(thisType.type, "function must be static or thisType must be defined.");
				
				auto thisParameter = new Parameter(f.location, thisType, "this", null);
				
				params = thisParameter ~ params;
			}
			
			f.type = QualType(new FunctionType(f.linkage, returnType, params.map!(p => p.pt).array(), fd.isVariadic));
			f.step = Step.Signed;
		}
		
		if(fd.fbody) {
			auto oldScope = currentScope;
			scope(exit) currentScope = oldScope;
			
			// Update scope.
			currentScope = f.dscope = new NestedScope(oldScope);
			
			// Register parameters.
			foreach(p; params) {
				p.step = Step.Processed;
				f.dscope.addSymbol(p);
			}
			
			// And visit.
			// TODO: change ast to allow any statement as function body;
			f.fbody = pass.visit(fd.fbody);
		}
		
		if(isAuto) {
			// If it isn't a static method, add this.
			if(!f.isStatic) {
				assert(thisType.type, "function must be static or thisType must be defined.");
				
				auto thisParameter = new Parameter(f.location, thisType, "this", null);
				
				params = thisParameter ~ params;
			}
			
			f.type = QualType(new FunctionType(f.linkage, returnType, params.map!(p => p.pt).array(), fd.isVariadic));
			f.step = Step.Signed;
		}
		
		switch(f.linkage) with(Linkage) {
			case D :
				auto typeMangle = pass.typeMangler.visit(f.type);
				f.mangle = "_D" ~ manglePrefix ~ (f.isStatic?typeMangle:("FM" ~ typeMangle[1 .. $]));
				break;
			
			case C :
				f.mangle = f.name;
				break;
			
			default:
				import std.conv;
				assert(0, "Linkage " ~ to!string(f.linkage) ~ " is not supported.");
		}
		
		f.step = Step.Processed;
		return f;
	}
	
	Symbol visit(Declaration d, Constructor c) {
		auto fd = cast(FunctionDeclaration) d;
		assert(fd);
		
		// XXX: maybe monad ?
		auto params = c.params = fd.params.map!(p => new Parameter(p.location, pass.visit(p.type), p.name, p.value?(pass.visit(p.value)):null)).array();
		
		manglePrefix = manglePrefix ~ to!string(c.name.length) ~ c.name;
		
		assert(thisType.type, "Constructor ?");
		if(thisType.isRef) {
			// Struct constructors are implemented as static function returning the struct.
			c.isStatic = true;
			
			returnType = ParamType(thisType.type, false);
			
			if(fd.fbody) {
				import d.ast.statement;
				AstStatement thisVar = new DeclarationStatement(new VariableDeclaration(c.location, QualAstType(thisType.type), "this", null));
				AstStatement ret = new AstReturnStatement(c.location, new ThisExpression(c.location));
				fd.fbody.statements = thisVar ~ fd.fbody.statements ~ ret;
			}
		} else {
			returnType = ParamType(getBuiltin(TypeKind.Void), false);
			
			auto thisParameter = new Parameter(c.location, thisType, "this", null);
			params = thisParameter ~ params;
		}
		
		c.type = QualType(new FunctionType(c.linkage, returnType, params.map!(p => p.pt).array(), fd.isVariadic));
		c.step = Step.Signed;
		
		if(fd.fbody) {
			auto oldScope = currentScope;
			scope(exit) currentScope = oldScope;
			
			// Update scope.
			currentScope = c.dscope = new NestedScope(oldScope);
			
			// Register parameters.
			foreach(p; params) {
				p.step = Step.Processed;
				c.dscope.addSymbol(p);
			}
			
			// And visit.
			c.fbody = pass.visit(fd.fbody);
		}
		
		assert(c.linkage == Linkage.D, "Linkage " ~ to!string(c.linkage) ~ " is not supported for constructors.");
		
		auto typeMangle = pass.typeMangler.visit(c.type);
		c.mangle = "_D" ~ manglePrefix ~ (c.isStatic?typeMangle:("FM" ~ typeMangle[1 .. $]));
		
		c.step = Step.Processed;
		return c;
	}
	
	Symbol visit(Declaration d, Method m) {
		return visit(d, cast(Function) m);
	}
	
	Variable visit(Declaration d, Variable v) {
		auto vd = cast(VariableDeclaration) d;
		assert(vd);
		
		Expression value;
		if(typeid({ return vd.type.type; }()) is typeid(AutoType)) {
			value = pass.visit(vd.value);
			v.type = value.type;
		} else {
			auto type = v.type = pass.visit(vd.type);
			value = vd.value
				? pass.visit(vd.value)
				: defaultInitializerVisitor.visit(v.location, type);
			value = buildImplicitCast(pass, d.location, type, value);
		}
		
		// Sanity check.
		if(vd.isEnum) {
			assert(v.isEnum);
		}
		
		if(v.isEnum) {
			value = evaluate(value);
		}
		
		v.value = value;
		
		v.mangle = v.name;
		if(v.isStatic) {
			assert(v.linkage == Linkage.D, "I mangle only D !");
			v.mangle = "_D" ~ manglePrefix ~ to!string(v.name.length) ~ v.name ~ typeMangler.visit(v.type);
		}
		
		v.step = Step.Processed;
		return v;
	}
	
	Symbol visit(Declaration d, Field f) {
		// XXX: hacky ! We force CTFE that way.
		auto oldIsEnum = f.isEnum;
		scope(exit) f.isEnum = oldIsEnum;
		
		f.isEnum = true;
		
		return visit(d, cast(Variable) f);
	}
	
	Symbol visit(Declaration d, TypeAlias a) {
		auto ad = cast(AliasDeclaration) d;
		assert(ad);
		
		a.type = pass.visit(ad.type);
		a.mangle = typeMangler.visit(a.type);
		
		a.step = Step.Processed;
		return a;
	}
	
	Symbol visit(Declaration d, Struct s) {
		auto sd = cast(StructDeclaration) d;
		assert(sd);
		
		auto oldManglePrefix = manglePrefix;
		auto oldScope = currentScope;
		auto oldThisType = thisType;
		auto oldFieldIndex = fieldIndex;
		
		scope(exit) {
			manglePrefix = oldManglePrefix;
			currentScope = oldScope;
			thisType = oldThisType;
			fieldIndex = oldFieldIndex;
		}
		
		currentScope = s.dscope = new SymbolScope(s, oldScope);
		
		auto type = QualType(new StructType(s));
		thisType = ParamType(type, true);
		
		// Update mangle prefix.
		manglePrefix = manglePrefix ~ to!string(s.name.length) ~ s.name;
		
		assert(s.linkage == Linkage.D);
		s.mangle = "S" ~ manglePrefix;
		
		fieldIndex = 0;
		
		auto dv = DeclarationVisitor(pass, s.linkage, false, true);
		
		auto members = dv.flatten(sd.members, s);
		s.step = Step.Populated;
		
		Field[] fields;
		auto otherSymbols = members.filter!((m) {
			if(auto f = cast(Field) m) {
				fields ~= f;
				return false;
			}
			
			return true;
		}).array();
		
		scheduler.require(fields);
		
		auto tuple = new TupleExpression(d.location, fields.map!(f => f.value).array());
		tuple.type = type;
		
		auto init = new Variable(d.location, type, "init", tuple);
		init.isStatic = true;
		init.mangle = "_D" ~ manglePrefix ~ to!string(init.name.length) ~ init.name ~ s.mangle;
		
		s.dscope.addSymbol(init);
		init.step = Step.Processed;
		
		s.members ~= init;
		s.members ~= fields;
		
		s.step = Step.Signed;
		
		scheduler.require(otherSymbols);
		s.members ~= otherSymbols;
		
		s.step = Step.Processed;
		return s;
	}
	
	Symbol visit(Declaration d, Class c) {
		auto cd = cast(ClassDeclaration) d;
		assert(cd);
		
		auto oldManglePrefix = manglePrefix;
		auto oldScope = currentScope;
		auto oldThisType = thisType;
		auto oldFieldIndex = fieldIndex;
		auto oldMethodIndex = methodIndex;
		
		scope(exit) {
			manglePrefix = oldManglePrefix;
			currentScope = oldScope;
			thisType = oldThisType;
			fieldIndex = oldFieldIndex;
			methodIndex = oldMethodIndex;
		}
		
		auto dscope = currentScope = c.dscope = new SymbolScope(c, oldScope);
		thisType = ParamType(new ClassType(c), false);
		
		// Update mangle prefix.
		manglePrefix = manglePrefix ~ to!string(c.name.length) ~ c.name;
		
		c.mangle = "C" ~ manglePrefix;
		
		Field[] baseFields;
		Method[] baseMethods;
		
		methodIndex = 0;
		if(c.mangle == "C6object6Object") {
			// Object is its own base class.
			c.base = c;
			
			auto vtblType = QualType(new PointerType(getBuiltin(TypeKind.Void)));
			vtblType.qualifier = TypeQualifier.Immutable;
			
			// TODO: use defaultinit.
			auto vtbl = new Field(cd.location, 0, vtblType, "__vtbl", null);
			vtbl.step = Step.Processed;
			
			baseFields = [vtbl];
			
			fieldIndex = 1;
		} else {
			foreach(i; cd.bases) {
				auto type = IdentifierVisitor!(function ClassType(identified) {
					static if(is(typeof(identified) : QualType)) {
						return cast(ClassType) identified.type;
					} else {
						return null;
					}
				})(pass).visit(i);
				
				assert(type, "Only classes are supported as base for now, " ~ typeid(type).toString() ~ " given.");
				
				c.base = type.dclass;
				break;
			}
			
			if(!c.base) {
				auto baseType = IdentifierVisitor!(function ClassType(parsed) {
					static if(is(typeof(parsed) : QualType)) {
						return cast(ClassType) parsed.type;
					} else {
						return null;
					}
				})(pass).visit(new BasicIdentifier(d.location, "Object"));
				
				assert(baseType, "Can't find object.Object");
				c.base = baseType.dclass;
			}
			
			scheduler.require(c.base);
			foreach(m; c.base.members) {
				if(auto field = cast(Field) m) {
					baseFields ~= field;
					fieldIndex = max(fieldIndex, field.index);
					
					c.dscope.addSymbol(field);
				} else if(auto method = cast(Method) m) {
					baseMethods ~= method;
					methodIndex = max(methodIndex, method.index);
				}
			}
			
			fieldIndex++;
		}
		
		auto dv = DeclarationVisitor(pass, c.linkage, false, true, true);
		
		auto members = dv.flatten(cd.members, c);
		
		c.step = Step.Signed;
		
		Method[] candidates = baseMethods;
		foreach(m; members) {
			if(auto method = cast(Method) m) {
				scheduler.require(method, Step.Signed);
				
				auto mt = cast(FunctionType) method.type.type;
				auto rt = mt.returnType;
				auto ats = mt.paramTypes[1 .. $];
				
				CandidatesLoop: foreach(ref candidate; candidates) {
					if(!candidate || m.name != candidate.name) {
						continue;
					}
					
					auto ct = cast(FunctionType) candidate.type.type;
					if(!ct || ct.isVariadic != mt.isVariadic) {
						continue;
					}
					
					auto crt = ct.returnType;
					auto cts = ct.paramTypes[1 .. $];
					if(ats.length != cts.length || rt.isRef != crt.isRef) {
						continue;
					}
					
					if(implicitCastFrom(pass, QualType(rt.type), QualType(crt.type)) < CastKind.Exact) {
						continue;
					}
					
					import std.range;
					foreach(at, ct; lockstep(ats, cts)) {
						if(at.isRef != ct.isRef) {
							continue CandidatesLoop;
						}
						
						if(implicitCastFrom(pass, QualType(ct.type), QualType(at.type)) < CastKind.Exact) {
							continue CandidatesLoop;
						}
					}
					
					if(method.index == 0) {
						method.index = candidate.index;
						candidate = null;
						break;
					} else {
						assert(0, "Override not marked as override !");
					}
				}
				
				if(method.index == 0) {
					assert(0, "Override not found for " ~ method.name);
				}
			}
		}
		
		// Remaining candidates must be added to scope.
		baseMethods.length = candidates.length;
		uint i = 0;
		foreach(candidate; candidates) {
			if(candidate) {
				c.dscope.addOverloadableSymbol(candidate);
				baseMethods[i++] = candidate;
			}
		}
		
		c.members = cast(Symbol[]) baseFields;
		c.members ~= baseMethods;
		scheduler.require(members);
		c.members ~= members;
		
		c.step = Step.Processed;
		return c;
	}
	
	Symbol visit(Declaration d, Enum e) {
		auto ed = cast(EnumDeclaration) d;
		assert(ed);
		
		assert(e.name, "anonymous enums must be flattened !");
		
		auto oldManglePrefix = manglePrefix;
		auto oldScope = currentScope;
		
		scope(exit) {
			manglePrefix = oldManglePrefix;
			currentScope = oldScope;
		}
		
		currentScope = e.dscope = new SymbolScope(e, oldScope);
		
		e.type = pass.visit(ed.type).type;
		auto type = new EnumType(e);
		
		TypeKind kind;
		if(auto t = cast(BuiltinType) e.type) {
			assert(isIntegral(t.kind), "enum are of integer type.");
			kind = t.kind;
		} else {
			assert(0, "enum are of integer type.");
		}
		
		manglePrefix = manglePrefix ~ to!string(e.name.length) ~ e.name;
		
		assert(e.linkage == Linkage.D);
		e.mangle = "E" ~ manglePrefix;
		
		foreach(vd; ed.entries) {
			auto v = new Variable(vd.location, QualType(type), vd.name);
			
			v.isStatic = true;
			v.isEnum = true;
			v.step = Step.Processed;
			
			e.dscope.addSymbol(v);
			e.entries ~= v;
		}
		
		e.step = Step.Signed;
		
		Expression previous;
		Expression one;
		import std.range;
		foreach(v, vd; lockstep(e.entries, ed.entries)) {
			v.step = Step.Signed;
			scope(exit) v.step = Step.Processed;
			
			if(vd.value) {
				v.value = pass.visit(vd.value);
			} else {
				if(previous) {
					if(!one) {
						one = new IntegerLiteral!true(vd.location, 1, kind);
					}
					
					v.value = new BinaryExpression(vd.location, QualType(e.type), BinaryOp.Add, previous, one);
				} else {
					v.value = new IntegerLiteral!true(vd.location, 0, kind);
				}
			}
			
			previous = v.value;
		}
		
		foreach(v; e.entries) {
			v.value = pass.evaluate(v.value);
		}
		
		e.step = Step.Processed;
		return e;
	}
	
	Symbol visit(Declaration d, Template t) {
		auto td = cast(TemplateDeclaration) d;
		assert(td);
		
		// XXX: compute a proper mangling for templates.
		t.mangle = manglePrefix ~ to!string(t.name.length) ~ t.name;
		
		auto oldScope = currentScope;
		scope(exit) currentScope = oldScope;
		
		currentScope = t.dscope = new SymbolScope(t, oldScope);
		
		// Register parameter int the scope.
		auto none = getBuiltin(TypeKind.None);
		foreach(uint i, p; td.parameters) {
			if(auto atp = cast(AstTypeTemplateParameter) p) {
				auto tp = new TypeTemplateParameter(atp.location, atp.name, i, none, none);
				currentScope.addSymbol(tp);
				t.parameters ~= tp;
			} else {
				assert(0, "Only type parameters are supported.");
			}
		}
		
		t.step = Step.Populated;
		
		// TODO: find a way to make that clean.
		foreach(i, p; td.parameters) {
			if(auto atp = cast(AstTypeTemplateParameter) p) {
				auto tp = cast(TypeTemplateParameter) t.parameters[i];
				assert(tp);
				
				tp.specialization = pass.visit(atp.specialization);
				tp.value = pass.visit(atp.value);
				
				tp.step = Step.Processed;
			} else {
				assert(0, "Only type parameters are supported.");
			}
		}
		
		// TODO: support multiple IFTI.
		foreach(m; t.members) {
			if(auto fun = cast(FunctionDeclaration) m) {
				if(fun.name != t.name) {
					continue;
				}
				
				t.ifti = fun.params.map!(p => pass.visit(p.type)).map!(t => QualType(t.type, t.qualifier)).array();
				break;
			}
		}
		
		t.step = Step.Processed;
		return t;
	}
}
