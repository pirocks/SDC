/**
 * Copyright 2010 Bernard Helyer
 * This file is part of SDC. SDC is licensed under the GPL.
 * See LICENCE or sdc.d for more details.
 */
module sdc.gen.semantic;

import std.range;

import llvm.c.Core;

import sdc.ast.declaration;
public import sdc.gen.sdcscope;



/**
 * I'm going to be honest here. Semantic is a big grab bag of shit
 * needed for codegen, intended to be passed around like a cheap
 * whore.
 */
final class Semantic
{
    LLVMContextRef context;
    LLVMModuleRef mod;
    LLVMBuilderRef builder;
    LLVMTypeRef functionType;
    LLVMValueRef currentFunction;
    
    this()
    {
        context = LLVMGetGlobalContext();
        builder = LLVMCreateBuilderInContext(context);
        mGlobalScope = new Scope();
    }
    
    void pushScope()
    {
        mScopeStack ~= new Scope();
    }
    
    void popScope()
    in { assert(mScopeStack.length >= 1); }
    body
    {
        disposedScope = mScopeStack[$ - 1];
        disposedScope.checkUnused();
        mScopeStack = mScopeStack[0 .. $ - 1];
    }
    
    int scopeDepth() @property
    {
        return mScopeStack.length;
    }
    
    Scope disposedScope;
    
    Scope currentScope() @property
    {
        if (mScopeStack.length >= 1) {
            return mScopeStack[$ - 1];
        }
        return mGlobalScope;
    }
    
    void setDeclaration(string name, Store val)
    {
        if (mScopeStack.length >= 1) {
            mScopeStack[$ - 1].setDeclaration(name, val);
        } else {
            mGlobalScope.setDeclaration(name, val);
        }
    }
    
    Store getDeclaration(string name, bool forceGlobal = false)
    {
        foreach (s; retro(mScopeStack)) if (!forceGlobal) {
            if (auto p = s.getDeclaration(name)) {
                return p;
            }
        }
        return mGlobalScope.getDeclaration(name);
    }
    
    
    protected Scope   mGlobalScope;
    protected Scope[] mScopeStack;
}
