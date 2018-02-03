package vm.lua;

#if linc_lua
import vm.lua.Api.*;
#end

#if js
import fengari.Fengari.*;
import fengari.Lua.*;
import fengari.Lauxlib.*;
import fengari.Lualib.*;
import fengari.State;
#end

import vm.lua.Macro.*;
import haxe.DynamicAccess;

using tink.CoreApi;

@:headerCode('#include "linc_lua.h"')
class Lua {
	public var version(default, never):String = VERSION;
	
	var l:State;
	static var funcs = [];
	
	public function new() {
		l = luaL_newstate();
	}
	
	public function run(s:String, ?globals:DynamicAccess<Any>):Outcome<Any, String> {
		if(globals != null) for(key in globals.keys()) setGlobalVar(key, globals.get(key));
		
		return if(luaL_dostring(l, s) == OK) {
			var lua_v:Int;
			var v:Any = null;
			while((lua_v = lua_gettop(l)) != 0) {
				v = toHaxeValue(l, lua_v);
				lua_pop(l, 1);
			}
			Success(v);
			
		} else {
			var v:String = lua_tostring(l, -1);
			lua_pop(l, 1);
			Failure(v);
		}
	}
	
	public function call(name:String, args:Array<Any>):Outcome<Any, String> {
		lua_getglobal(l, name);
		for(arg in args) toLuaValue(l, arg);
		
		return if(lua_pcall(l, args.length, 1, 0) == OK) {
			var result = toHaxeValue(l, -1);
			lua_pop(l, 1);
			Success(result);
		} else {
			var v:String = lua_tostring(l, -1);
			lua_pop(l, 1);
			Failure(v);
		}
	}
	
	public function loadLibs(libs:Array<String>) {
		for(lib in libs) {
			var openf = 
				switch lib {
					case 'base': luaopen_base;
					case 'debug': luaopen_debug;
					case 'io': luaopen_io;
					case 'math': luaopen_math;
					case 'os': luaopen_os;
					case 'package': luaopen_package;
					case 'string': luaopen_string;
					case 'table': luaopen_table;
					case 'coroutine': luaopen_coroutine;
					case _: null;
				}
			if(openf != null) {
				luaL_requiref(l, lib, openf, true);
				lua_settop(l, 0);
			}
		}
	}
	
	public function setGlobalVar(name:String, value:Any) {
		toLuaValue(l, value);
		lua_setglobal(l, name);
	}
	
	public function unsetGlobalVar(name:String) {
		lua_pushnil(l);
		lua_setglobal(l, name);
	}
	
	public function destroy() {
		lua_close(l);
		l = null;
	}
	
	static function toLuaValue(l, v:Any):Int {
		switch Type.typeof(v) {
			case TNull: lua_pushnil(l);
			case TBool: lua_pushboolean(l, v);
			case TFloat | TInt: lua_pushnumber(l, v);
			case TClass(String): lua_pushstring(l, (v:String));
			case TClass(Array):
				var arr:Array<Any> = v;
				lua_createtable(l, arr.length, 0);
				for(i in 0...arr.length) {
					lua_pushnumber(l, i + 1); // 1-based
					toLuaValue(l, arr[i]);
					lua_settable(l, -3);
				}
			case TFunction:
				#if cpp
				lua_pushnumber(l, funcs.push(v) - 1); // FIXME: this seems to leak like hell, but I have no idea how to store the function reference properly
				#else
				lua_pushlightuserdata(l, v);
				#end
				lua_pushcclosure(l, #if cpp _callback #elseif js callback #end, 1);
			case TObject:
				
				lua_newtable(l);
				var obj:DynamicAccess<Any> = v;
				for(key in obj.keys()) {
					lua_pushstring(l, key);
					toLuaValue(l, obj.get(key));
					lua_settable(l, -3);
				}
			case TClass(_):
				lua_newtable(l);
				for(key in Type.getInstanceFields(Type.getClass(v))) {
					lua_pushstring(l, key);
					toLuaValue(l, Reflect.getProperty(v, key));
					lua_settable(l, -3);
				}
			case t: throw 'TODO $t';
		}
		return 1;
	}
	
	static function toHaxeValue(l, i:Int):Any {
		return switch lua_type(l, i) {
			case t if (t == TNIL): null;
			case t if (t == TNUMBER): lua_tonumber(l, i);
			case t if (t == TTABLE): toHaxeObj(l, i);
			case t if (t == TSTRING): lua_tostring(l, i);
			case t if (t == TBOOLEAN): lua_toboolean(l, i);
			case t if (t == TFUNCTION): 
				switch lua_tocfunction(l, i) {
					case null: 
						var ref = luaL_ref(l, REGISTRYINDEX);
						lua_pushnil(l); // luaL_ref pops the stack, we fill it again
						Reflect.makeVarArgs(function(args) {
							lua_rawgeti(l, REGISTRYINDEX, ref);
							for(arg in args) toLuaValue(l, arg);
							if(lua_pcall(l, args.length, 1, 0) == OK) {
								var result = toHaxeValue(l, -1);
								lua_pop(l, 1);
								return result;
							} else {
								var v:String = lua_tostring(l, -1);
								lua_pop(l, 1);
								throw v;
							}
						});
					case f: throw "CFUNCTION not supported";
				}
			case t if (t == TUSERDATA): throw 'TUSERDATA not supported';
			case t if (t == TTHREAD): throw 'TTHREAD not supported';
			case t if (t == TLIGHTUSERDATA): throw 'TLIGHTUSERDATA not supported';
			case t: throw 'unreachable ($t)';
		}
	}
	
	static function toHaxeObj(l, i:Int):Any {
		var count = 0;
		var array = true;
		
		loopTable(l, i, {
			if(array) {
				if(lua_type(l, -2) != TNUMBER) array = false;
				else {
					var index = lua_tonumber(l, -2);
					if(index < 0 || Std.int(index) != index) array = false;
				}
			}
			count++;
		});
		
		return 
		if(count == 0) {
			{};
		} else if(array) {
			var v = [];
			loopTable(l, i, {
				var index = Std.int(lua_tonumber(l, -2)) - 1;
				v[index] = toHaxeValue(l, -1);
			});
			cast v;
		} else {
			var v:DynamicAccess<Any> = {};
			loopTable(l, i, {
				switch lua_type(l, -2) {
					case t if(t == TSTRING): v.set(lua_tostring(l, -2), toHaxeValue(l, -1));
					case t if(t == TNUMBER):v.set(Std.string(lua_tonumber(l, -2)), toHaxeValue(l, -1));
				}
			});
			cast v;
		}
	}
	
	#if cpp static var _callback = cpp.Callable.fromStaticFunction(callback); #end
	static function callback(l) {
		var numArgs = lua_gettop(l);
		var f = 
			#if cpp
			funcs[cast lua_tonumber(l, lua_upvalueindex(1))];
			#else
			lua_topointer(l, lua_upvalueindex(1));
			#end
		var args = [];
		for(i in 0...numArgs) args[i] = toHaxeValue(l, i + 1);
		var result = Reflect.callMethod(null, f, args);
		return toLuaValue(l, result);
	}
	
	static function printStack(l, depth:Int) {
		for(i in 1...depth + 1) {
			var t:String = lua_typename(l, lua_type(l, -i));
			var v = toHaxeValue(l, -i);
			trace(-i, t, v);
		}
	}
}