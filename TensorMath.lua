local wrap = require 'cwrap'

require 'torchcwrap'

local interface = wrap.CInterface.new()
local method = wrap.CInterface.new()
local argtypes = wrap.CInterface.argtypes

-- 16-bit floating-point type
-- Definition lifted from CUDA.
-- CPU support limited to copy/construction/storage.
argtypes['half'] = {
  helpname = function(arg)
                return 'half'
             end,

  declare = function(arg)
     -- if it is a number we initialize here
     local default = tonumber(tostring(arg.default)) or 0
     return string.format("%s arg%d = TH_float2half(%g);", 'half', arg.i, default)
  end,

  check = function(arg, idx)
     return string.format("lua_isnumber(L, %d)", idx)
  end,

  read = function(arg, idx)
     return string.format("arg%d = TH_float2half(lua_tonumber(L, %d));", arg.i, idx)
  end,

  init = function(arg)
            -- otherwise do it here
            if arg.default then
               local default = tostring(arg.default)
               if not tonumber(default) then
                  return string.format("arg%d = %s  ;", arg.i, default)
               end
            end
         end,

  carg = function(arg)
            return string.format('arg%d', arg.i)
         end,

  creturn = function(arg)
               return string.format('arg%d', arg.i)
            end,

  precall = function(arg)
               if arg.returned then
                  return string.format('lua_pushnumber(L, TH_half2float(arg%d));', arg.i)
               end
            end,

  postcall = function(arg)
                if arg.creturned then
                   return string.format('lua_pushnumber(L, (lua_Number)TH_half2float(arg%d));', arg.i)
                end
             end
}

argtypes['ptrdiff_t'] = {

  helpname = function(arg)
                return 'ptrdiff_t'
             end,

  declare = function(arg)
               -- if it is a number we initialize here
               local default = tonumber(tostring(arg.default)) or 0
               return string.format("%s arg%d = %g;", 'ptrdiff_t', arg.i, default)
            end,

  check = function(arg, idx)
             return string.format("lua_isnumber(L, %d)", idx)
          end,

  read = function(arg, idx)
            return string.format("arg%d = (%s)lua_tonumber(L, %d);", arg.i, 'ptrdiff_t', idx)
         end,

  init = function(arg)
            -- otherwise do it here
            if arg.default then
               local default = tostring(arg.default)
               if not tonumber(default) then
                  return string.format("arg%d = %s;", arg.i, default)
               end
            end
         end,

  carg = function(arg)
            return string.format('arg%d', arg.i)
         end,

  creturn = function(arg)
               return string.format('arg%d', arg.i)
            end,

  precall = function(arg)
               if arg.returned then
                  return string.format('lua_pushnumber(L, (lua_Number)arg%d);', arg.i)
               end
            end,

  postcall = function(arg)
                if arg.creturned then
                   return string.format('lua_pushnumber(L, (lua_Number)arg%d);', arg.i)
                end
             end
}

interface:print([[
#include "TH.h"
#include "THMath.h"
#include "luaT.h"
#include "utils.h"
]])

-- specific to torch: we generate a 'dispatch' function
-- first we create a helper function
-- note that it let the "torch" table on the stack
interface:print([[
static const void* torch_istensortype(lua_State *L, const char *tname)
{
  if(!tname)
    return NULL;

  if(!luaT_pushmetatable(L, tname))
    return NULL;

  lua_pushstring(L, "torch");
  lua_rawget(L, -2);
  if(lua_istable(L, -1))
    return tname;
  else
  {
    lua_pop(L, 2);
    return NULL;
  }

  return NULL;
}
]])

interface:print([[
static int torch_isnonemptytable(lua_State *L, int idx)
{
  int empty;
  if (!lua_istable(L, idx)) return 0;

  lua_rawgeti(L, idx, 1);
  empty = lua_isnil(L, -1);
  lua_pop(L, 1);
  return !empty;
}
]])


interface:print([[
static const void* torch_istensorarray(lua_State *L, int idx)
{
  const char* tname;
  int tensor_idx;
  if (!torch_isnonemptytable(L, idx)) return 0;

  lua_checkstack(L, 3);
  lua_rawgeti(L, idx, 1);
  tensor_idx = lua_gettop(L);
  tname = (torch_istensortype(L, luaT_typename(L, -1)));
  lua_remove(L, tensor_idx);
  return tname;
}
]])

interface.dispatchregistry = {}
function interface:wrap(name, ...)
   -- usual stuff
   wrap.CInterface.wrap(self, name, ...)

   -- dispatch function
   if not interface.dispatchregistry[name] then
      interface.dispatchregistry[name] = true
      table.insert(interface.dispatchregistry, {name=name, wrapname=string.format("torch_%s", name)})

      interface:print(string.gsub([[
static int torch_NAME(lua_State *L)
{
  int narg = lua_gettop(L);
  const void *tname;
  if(narg >= 1 && (tname = torch_istensortype(L, luaT_typename(L, 1)))) /* first argument is tensor? */
  {
  }
  else if(narg >= 2 && (tname = torch_istensortype(L, luaT_typename(L, 2)))) /* second? */
  {
  }
  else if(narg >= 1 && (tname = torch_istensorarray(L, 1))) /* torch table argument? */
  {
  }
  else if(narg >= 1 && lua_type(L, narg) == LUA_TSTRING
	  && (tname = torch_istensortype(L, lua_tostring(L, narg)))) /* do we have a valid tensor type string then? */
  {
    lua_remove(L, -2);
  }
  else if(!(tname = torch_istensortype(L, torch_getdefaulttensortype(L))))
    luaL_error(L, "internal error: the default tensor type does not seem to be an actual tensor");

  lua_pushstring(L, "NAME");
  lua_rawget(L, -2);
  if(lua_isfunction(L, -1))
  {
    lua_insert(L, 1);
    lua_pop(L, 2); /* the two tables we put on the stack above */
    lua_call(L, lua_gettop(L)-1, LUA_MULTRET);
  }
  else
    return luaL_error(L, "%s does not implement the torch.NAME() function", tname);

  return lua_gettop(L);
}
]], 'NAME', name))
  end
end

function interface:dispatchregister(name)
   local txt = self.txt
   table.insert(txt, string.format('static const struct luaL_Reg %s [] = {', name))
   for _,reg in ipairs(self.dispatchregistry) do
      table.insert(txt, string.format('{"%s", %s},', reg.name, reg.wrapname))
   end
   table.insert(txt, '{NULL, NULL}')
   table.insert(txt, '};')
   table.insert(txt, '')
   self.dispatchregistry = {}
end

interface:print('/* WARNING: autogenerated file */')
interface:print('')

local function wrap(...)
   local args = {...}

   -- interface
   interface:wrap(...)

   -- method: we override things possibly in method table field
   for _,x in ipairs(args) do
      if type(x) == 'table' then -- ok, now we have a list of args
         for _, arg in ipairs(x) do
            if arg.method then
               for k,v in pairs(arg.method) do
                  if v == 'nil' then -- special case, we erase the field
                     arg[k] = nil
                  else
                     arg[k] = v
                  end
               end
            end
         end
      end
   end
   local unpack = unpack or table.unpack
    method:wrap(unpack(args))
end

local reals = {ByteTensor='unsigned char',
               CharTensor='char',
               ShortTensor='short',
               IntTensor='int',
               LongTensor='long',
               FloatTensor='float',
               HalfTensor='half',
               DoubleTensor='double'}

local accreals = {ByteTensor='long',
               CharTensor='long',
               ShortTensor='long',
               IntTensor='long',
               LongTensor='long',
               FloatTensor='double',
               HalfTensor='float',
               DoubleTensor='double'}

for _,Tensor in ipairs({"ByteTensor", "CharTensor",
                        "ShortTensor", "IntTensor", "LongTensor",
                        "FloatTensor", "HalfTensor", "DoubleTensor"}) do

   local real = reals[Tensor]
   local accreal = accreals[Tensor]

   function interface.luaname2wrapname(self, name)
      return string.format('torch_%s_%s', Tensor, name)
   end

   function method.luaname2wrapname(self, name)
      return string.format('m_torch_%s_%s', Tensor, name)
   end

   local function cname(name)
      return string.format('TH%s_%s', Tensor, name)
   end

   local function lastdim(argn)
      return function(arg)
                return string.format("TH%s_nDimension(%s)", Tensor, arg.args[argn]:carg())
             end
   end

   local function lastdimarray(argn)
      return function(arg)
                return string.format("TH%s_nDimension(arg%d_data[0])", Tensor, arg.args[argn].i)
             end
   end

   wrap("zero",
        cname("zero"),
        {{name=Tensor, returned=true}})

   wrap("fill",
        cname("fill"),
        {{name=Tensor, returned=true},
         {name=real}})

   wrap("zeros",
        cname("zeros"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name="LongArg"}})

   wrap("ones",
        cname("ones"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name="LongArg"}})

   wrap("reshape",
        cname("reshape"),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor},
         {name="LongArg"}})

   wrap("gather",
        cname("gather"),
        {{name=Tensor, default=true, returned=true,
          init=function(arg)
                  return table.concat(
                     {
                        arg.__metatable.init(arg),
                        string.format("THLongStorage* %s_size = THLongTensor_newSizeOf(%s);", arg:carg(), arg.args[4]:carg()),
                        string.format("TH%s_resize(%s, %s_size, NULL);", Tensor, arg:carg(), arg:carg()),
                        string.format("THLongStorage_free(%s_size);", arg:carg())
                     }, '\n')
               end
         },
         {name=Tensor},
         {name="index"},
         {name="IndexTensor", noreadadd=true}})

   wrap("scatter",
        cname("scatter"),
        {{name=Tensor, returned=true},
         {name="index"},
         {name="IndexTensor", noreadadd=true},
         {name=Tensor}},
        cname("scatterFill"),
        {{name=Tensor, returned=true},
         {name="index"},
         {name="IndexTensor", noreadadd=true},
         {name=real}})

   wrap("dot",
        cname("dot"),
        {{name=Tensor},
         {name=Tensor},
         {name=accreal, creturned=true}})

   wrap("equal",
        cname("equal"),
        {{name=Tensor},
         {name=Tensor},
         {name="boolean", creturned=true}})

   if Tensor ~= 'HalfTensor' then
   wrap("add",
        cname("add"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=real}},
        cname("cadd"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=real, default=1},
         {name=Tensor}})

   wrap("csub",
     cname("sub"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
       {name=Tensor, method={default=1}},
       {name=real}},
     cname("csub"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
       {name=Tensor, method={default=1}},
       {name=real, default=1},
       {name=Tensor}})

   wrap("mul",
        cname("mul"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=real}})

   wrap("div",
        cname("div"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=real}})

   wrap("fmod",
        cname("fmod"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=real}})

   wrap("remainder",
        cname("remainder"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=real}})

   -- mod alias
   wrap("mod",
        cname("fmod"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=real}})

   wrap("clamp",
        cname("clamp"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=real},
         {name=real}})


   wrap("match",
        cname("match"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor},
         {name=Tensor},
         {name=real, default=1}
        })

   wrap("cmul",
        cname("cmul"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=Tensor}})

   wrap("cpow",
        cname("cpow"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=Tensor}})

   wrap("cdiv",
        cname("cdiv"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=Tensor}})

   wrap("cfmod",
        cname("cfmod"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=Tensor}})

   wrap("cremainder",
        cname("cremainder"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=Tensor}})

   -- cmod alias
   wrap("cmod",
        cname("cfmod"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=Tensor}})

   wrap("addcmul",
        cname("addcmul"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=real, default=1},
         {name=Tensor},
         {name=Tensor}})

   wrap("addcdiv",
        cname("addcdiv"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}},
         {name=real, default=1},
         {name=Tensor},
         {name=Tensor}})

   wrap("mv",
        cname("addmv"),
        {{name=Tensor, default=true, returned=true, method={default='nil'},
          init=function(arg)
                  return table.concat(
                     {
                        arg.__metatable.init(arg),
                        string.format("TH%s_resize1d(%s, %s->size[0]);", Tensor, arg:carg(), arg.args[5]:carg())
                     }, '\n')
               end,
          precall=function(arg)
                  return table.concat(
                     {
                        string.format("TH%s_zero(%s);", Tensor, arg:carg()),
                        arg.__metatable.precall(arg)
                     }, '\n')
               end,
       },
         {name=real, default=0, invisible=true},
         {name=Tensor, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=2},
         {name=Tensor, dim=1}}
     )

   wrap("mm",
        cname("addmm"),
        {{name=Tensor, default=true, returned=true, method={default='nil'},
          init=function(arg)
                  return table.concat(
                     {
                        arg.__metatable.init(arg),
                        string.format("TH%s_resize2d(%s, %s->size[0], %s->size[1]);", Tensor, arg:carg(), arg.args[5]:carg(), arg.args[6]:carg())
                     }, '\n')
               end,
          precall=function(arg)
                  return table.concat(
                     {
                        string.format("TH%s_zero(%s);", Tensor, arg:carg()),
                        arg.__metatable.precall(arg)
                     }, '\n')
               end,
       },
         {name=real, default=0, invisible=true},
         {name=Tensor, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=2},
         {name=Tensor, dim=2}}
     )

   wrap("bmm",
        cname("baddbmm"),
        {{name=Tensor, default=true, returned=true, method={default='nil'},
          init=function(arg)
                  return table.concat(
                     {
                        arg.__metatable.init(arg),
                        string.format("TH%s_resize3d(%s, %s->size[0], %s->size[1], %s->size[2]);",
                                      Tensor, arg:carg(), arg.args[5]:carg(), arg.args[5]:carg(), arg.args[6]:carg())
                     }, '\n')
               end,
          precall=function(arg)
                  return table.concat(
                     {
                        string.format("TH%s_zero(%s);", Tensor, arg:carg()),
                        arg.__metatable.precall(arg)
                     }, '\n')
               end,
       },
         {name=real, default=0, invisible=true},
         {name=Tensor, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=3},
         {name=Tensor, dim=3}}
     )

   wrap("ger",
        cname("addr"),
        {{name=Tensor, default=true, returned=true, method={default='nil'},
          init=function(arg)
                  return table.concat(
                     {
                        arg.__metatable.init(arg),
                        string.format("TH%s_resize2d(%s, %s->size[0], %s->size[0]);", Tensor, arg:carg(), arg.args[5]:carg(), arg.args[6]:carg())
                     }, '\n')
               end,
          precall=function(arg)
                     return table.concat(
                        {
                           string.format("TH%s_zero(%s);", Tensor, arg:carg()),
                           arg.__metatable.precall(arg)
                        }, '\n')
                  end
       },
        {name=real, default=1, invisible=true},
        {name=Tensor, default=1, invisible=true},
        {name=real, default=1, invisible=true},
        {name=Tensor, dim=1},
        {name=Tensor, dim=1}}
     )

   for _,f in ipairs({
                        {name="addmv",   dim1=1, dim2=2, dim3=1},
                        {name="addmm",   dim1=2, dim2=2, dim3=2},
                        {name="addr",    dim1=2, dim2=1, dim3=1},
                        {name="addbmm",  dim1=2, dim2=3, dim3=3},
                        {name="baddbmm", dim1=3, dim2=3, dim3=3},
                     }
                  ) do

      interface:wrap(f.name,
                     cname(f.name),
                     {{name=Tensor, default=true, returned=true},
                      {name=real, default=1},
                      {name=Tensor, dim=f.dim1},
                      {name=real, default=1},
                      {name=Tensor, dim=f.dim2},
                      {name=Tensor, dim=f.dim3}})

      -- there is an ambiguity here, hence the more complicated setup
      method:wrap(f.name,
                  cname(f.name),
                  {{name=Tensor, returned=true, dim=f.dim1},
                   {name=real, default=1, invisible=true},
                   {name=Tensor, default=1, dim=f.dim1},
                   {name=real, default=1},
                   {name=Tensor, dim=f.dim2},
                   {name=Tensor, dim=f.dim3}},
                  cname(f.name),
                  {{name=Tensor, returned=true, dim=f.dim1},
                   {name=real},
                   {name=Tensor, default=1, dim=f.dim1},
                   {name=real},
                   {name=Tensor, dim=f.dim2},
                   {name=Tensor, dim=f.dim3}})
   end

   wrap("numel",
        cname("numel"),
        {{name=Tensor},
         {name="ptrdiff_t", creturned=true}})

   for _,name in ipairs({"cumsum", "cumprod"}) do
      wrap(name,
           cname(name),
           {{name=Tensor, default=true, returned=true},
            {name=Tensor},
            {name="index", default=1}})
   end

   wrap("sum",
        cname("sumall"),
        {{name=Tensor},
         {name=accreal, creturned=true}},
        cname("sum"),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor},
         {name="index"}})

   wrap("prod",
        cname("prodall"),
        {{name=Tensor},
         {name=accreal, creturned=true}},
        cname("prod"),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor},
         {name="index"}})

   for _,name in ipairs({"min", "max"}) do
      wrap(name,
           cname(name .. "all"),
           {{name=Tensor},
            {name=real, creturned=true}},
           cname(name),
           {{name=Tensor, default=true, returned=true},
            {name="IndexTensor", default=true, returned=true, noreadadd=true},
            {name=Tensor},
            {name="index"}})
   end

   for _,name in ipairs({"cmin", "cmax"}) do
      wrap(name,
           cname(name),
           {{name=Tensor, default=true, returned=true},
            {name=Tensor, method={default=1}},
            {name=Tensor}},
           cname(name .. "Value"),
           {{name=Tensor, default=true, returned=true},
            {name=Tensor, method={default=1}},
            {name=real}})
   end

   wrap("trace",
        cname("trace"),
        {{name=Tensor},
         {name=accreal, creturned=true}})

   wrap("cross",
        cname("cross"),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor},
         {name=Tensor},
         {name="index", default=0}})

   wrap("diag",
        cname("diag"),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor},
         {name="long", default=0}})

   wrap("eye",
        cname("eye"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name="long"},
         {name="long", default=0}})

   wrap("range",
        cname("range"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=accreal},
         {name=accreal},
         {name=accreal, default=1}})

   wrap("randperm",
        cname("randperm"),
        {{name=Tensor, default=true, returned=true, method={default='nil'},
          postcall=function(arg)
                      return table.concat(
                         {
                            arg.__metatable.postcall(arg),
                            string.format("TH%s_add(%s, %s, 1);", Tensor, arg:carg(), arg:carg())
                         }, '\n')
                   end},
         {name="Generator", default=true},
         {name="long"}})

   wrap("sort",
        cname("sort"),
        {{name=Tensor, default=true, returned=true},
         {name="IndexTensor", default=true, returned=true, noreadadd=true},
         {name=Tensor},
         {name="index", default=lastdim(3)},
         {name="boolean", default=0}})

wrap("topk",
     cname("topk"),
     {{name=Tensor, default=true, returned=true},
        {name="IndexTensor", default=true, returned=true, noreadadd=true},
        {name=Tensor},
        {name="long", default=1},
        {name="index", default=lastdim(3)},
        {name="boolean", default=0},
        {name="boolean", default=0}})

   wrap("kthvalue",
        cname("kthvalue"),
        {{name=Tensor, default=true, returned=true},
         {name="IndexTensor", default=true, returned=true, noreadadd=true},
         {name=Tensor},
         {name="long"},
         {name="index", default=lastdim(3)}})

   wrap("mode",
       cname("mode"),
       {{name=Tensor, default=true, returned=true},
           {name="IndexTensor", default=true, returned=true, noreadadd=true},
           {name=Tensor},
           {name="index", default=lastdim(3)}})

   wrap("median",
        cname("median"),
        {{name=Tensor, default=true, returned=true},
         {name="IndexTensor", default=true, returned=true, noreadadd=true},
         {name=Tensor},
         {name="index", default=lastdim(3)}})

   wrap("tril",
        cname("tril"),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor},
         {name="int", default=0}})

   wrap("triu",
        cname("triu"),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor},
         {name="int", default=0}})

   wrap("cat",
        cname("cat"),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor},
         {name=Tensor},
         {name="index", default=lastdim(2)}},
        cname("catArray"),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor .. "Array"},
         {name="index", default=lastdimarray(2)}})

   if Tensor == 'ByteTensor' then -- we declare this only once
      interface:print(
         [[
static long THRandom_random2__(THGenerator *gen, long a, long b)
{
  THArgCheck(b >= a, 2, "upper bound must be larger than lower bound");
  return((THRandom_random(gen) % (b+1-a)) + a);
}

static long THRandom_random1__(THGenerator *gen, long b)
{
  THArgCheck(b > 0, 1, "upper bound must be strictly positive");
  return(THRandom_random(gen) % b + 1);
}
         ]])
   end

   interface:print(string.gsub(
                      [[
static void THTensor_random2__(THTensor *self, THGenerator *gen, long a, long b)
{
  THArgCheck(b >= a, 2, "upper bound must be larger than lower bound");
  TH_TENSOR_APPLY(real, self, *self_data = ((THRandom_random(gen) % (b+1-a)) + a);)
}

static void THTensor_random1__(THTensor *self, THGenerator *gen, long b)
{
  THArgCheck(b > 0, 1, "upper bound must be strictly positive");
  TH_TENSOR_APPLY(real, self, *self_data = (THRandom_random(gen) % b + 1);)
}
]], 'Tensor', Tensor):gsub('real', real))

   wrap('random',
        'THRandom_random2__',
        {{name='Generator', default=true},
         {name='long'},
         {name='long'},
         {name='long', creturned=true}},
        'THRandom_random1__',
        {{name='Generator', default=true},
         {name='long'},
         {name='long', creturned=true}},
        'THRandom_random',
        {{name='Generator', default=true},
         {name='long', creturned=true}},
        cname("random2__"),
        {{name=Tensor, returned=true},
         {name='Generator', default=true},
         {name='long'},
         {name='long'}},
        cname("random1__"),
        {{name=Tensor, returned=true},
         {name='Generator', default=true},
         {name='long'}},
        cname("random"),
        {{name=Tensor, returned=true},
         {name='Generator', default=true}})

   wrap("geometric",
     "THRandom_geometric",
     {{name="Generator", default=true},
      {name="double"},
      {name="double", creturned=true}},
     cname("geometric"),
     {{name=Tensor, returned=true},
      {name="Generator", default=true},
      {name="double"}})

   wrap("bernoulli",
      "THRandom_bernoulli",
      {{name="Generator", default=true},
       {name="double", default=0.5},
       {name="double", creturned=true}},
      cname("bernoulli"),
      {{name=Tensor, returned=true},
       {name="Generator", default=true},
       {name="double", default=0.5}},
      cname("bernoulli_FloatTensor"),
      {{name=Tensor, returned=true},
       {name="Generator", default=true},
       {name="FloatTensor"}},
      cname("bernoulli_DoubleTensor"),
      {{name=Tensor, returned=true},
       {name="Generator", default=true},
       {name="DoubleTensor"}})

   wrap("squeeze",
        cname("squeeze"),
        {{name=Tensor, default=true, returned=true, postcall=function(arg)
                                                                local txt = {}
                                                                if arg.returned then
                                                                   table.insert(txt, string.format('if(arg%d->nDimension == 1 && arg%d->size[0] == 1)', arg.i, arg.i)) -- number
                                                                   table.insert(txt, string.format('lua_pushnumber(L, (lua_Number)(*TH%s_data(arg%d)));', Tensor, arg.i))
                                                                end
                                                                return table.concat(txt, '\n')
                                                             end},
         {name=Tensor}},
        cname("squeeze1d"),
        {{name=Tensor, default=true, returned=true,

          postcall=
             function(arg)
                local txt = {}
                if arg.returned then
                   table.insert(txt, string.format('if(!hasdims && arg%d->nDimension == 1 && arg%d->size[0] == 1)', arg.i, arg.i)) -- number
                   table.insert(txt, string.format('lua_pushnumber(L, (lua_Number)(*TH%s_data(arg%d)));}', Tensor, arg.i))
                end
                return table.concat(txt, '\n')
             end},

         {name=Tensor,

          precall=
             function(arg)
                return string.format('{int hasdims = arg%d->nDimension > 1;', arg.i)
             end},

         {name="index"}})

   wrap("sign",
        cname("sign"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}}})

   wrap("conv2",
        cname("conv2Dmul"),
        {{name=Tensor, default=true, returned=true},
         {name=real, default=0, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=2},
         {name=Tensor, dim=2},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name='charoption', values={'V', 'F'}, default='V'},
         {name='charoption', default="C", invisible=true}},
        cname("conv2Dcmul"),
        {{name=Tensor, default=true, returned=true},
         {name=real, default=0, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=3},
         {name=Tensor, dim=3},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name='charoption', values={'V', 'F'}, default='V'},
         {name='charoption', default="C", invisible=true}},
        cname("conv2Dmv"),
        {{name=Tensor, default=true, returned=true},
         {name=real, default=0, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=3},
         {name=Tensor, dim=4},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name='charoption', values={'V', 'F'}, default='V'},
         {name='charoption', default="C", invisible=true}}
     )

   wrap("xcorr2",
        cname("conv2Dmul"),
        {{name=Tensor, default=true, returned=true},
         {name=real, default=0, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=2},
         {name=Tensor, dim=2},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name='charoption', values={'V', 'F'}, default='V'},
         {name='charoption', default="X", invisible=true}},
        cname("conv2Dcmul"),
        {{name=Tensor, default=true, returned=true},
         {name=real, default=0, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=3},
         {name=Tensor, dim=3},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name='charoption', values={'V', 'F'}, default='V'},
         {name='charoption', default="X", invisible=true}},
        cname("conv2Dmv"),
        {{name=Tensor, default=true, returned=true},
         {name=real, default=0, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=3},
         {name=Tensor, dim=4},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name='charoption', values={'V', 'F'}, default='V'},
         {name='charoption', default="X", invisible=true}}
     )

   wrap("conv3",
        cname("conv3Dmul"),
        {{name=Tensor, default=true, returned=true},
         {name=real, default=0, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=3},
         {name=Tensor, dim=3},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name='charoption', values={'V', 'F'}, default='V'},
         {name='charoption', default="C", invisible=true}},
        cname("conv3Dcmul"),
        {{name=Tensor, default=true, returned=true},
         {name=real, default=0, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=4},
         {name=Tensor, dim=4},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name='charoption', values={'V', 'F'}, default='V'},
         {name='charoption', default="C", invisible=true}},
        cname("conv3Dmv"),
        {{name=Tensor, default=true, returned=true},
         {name=real, default=0, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=4},
         {name=Tensor, dim=5},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name='charoption', values={'V', 'F'}, default='V'},
         {name='charoption', default="C", invisible=true}}
     )

   wrap("xcorr3",
        cname("conv3Dmul"),
        {{name=Tensor, default=true, returned=true},
         {name=real, default=0, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=3},
         {name=Tensor, dim=3},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name='charoption', values={'V', 'F'}, default='V'},
         {name='charoption', default="X", invisible=true}},
        cname("conv3Dcmul"),
        {{name=Tensor, default=true, returned=true},
         {name=real, default=0, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=4},
         {name=Tensor, dim=4},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name='charoption', values={'V', 'F'}, default='V'},
         {name='charoption', default="X", invisible=true}},
        cname("conv3Dmv"),
        {{name=Tensor, default=true, returned=true},
         {name=real, default=0, invisible=true},
         {name=real, default=1, invisible=true},
         {name=Tensor, dim=4},
         {name=Tensor, dim=5},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name=real, default=1, invisible=true},
         {name='charoption', values={'V', 'F'}, default='V'},
         {name='charoption', default="X", invisible=true}}
     )
  end

   for _,name in pairs({'lt','gt','le','ge','eq','ne'}) do
      wrap(name,
           cname(name .. 'Value'),
           {{name='ByteTensor',default=true, returned=true},
            {name=Tensor},
            {name=real}},
           cname(name .. 'ValueT'),
           {{name=Tensor, returned=true},
            {name=Tensor},
            {name=real}},
           cname(name .. 'Tensor'),
           {{name='ByteTensor',default=true, returned=true},
            {name=Tensor},
            {name=Tensor}},
           cname(name .. 'TensorT'),
           {{name=Tensor, returned=true},
            {name=Tensor},
            {name=Tensor}})
   end

   wrap("nonzero",
        cname("nonzero"),
        {{name="IndexTensor", default=true, returned=true},
         {name=Tensor}})

   if Tensor == 'ByteTensor' then
     -- Logical accumulators only apply to ByteTensor
      for _,name in ipairs({'all', 'any'}) do
        wrap(name,
             cname('logical' .. name),
             {{name=Tensor},
		{name="boolean", creturned=true}})
      end
   end

   if Tensor == 'IntTensor' then
         wrap("abs",
              cname("abs"),
              {{name=Tensor, default=true, returned=true, method={default='nil'}},
               {name=Tensor, method={default=1}}},
              "abs",
              {{name=real},
               {name=real, creturned=true}})
   elseif Tensor == 'LongTensor' then
         wrap("abs",
              cname("abs"),
              {{name=Tensor, default=true, returned=true, method={default='nil'}},
               {name=Tensor, method={default=1}}},
              "labs",
              {{name=real},
               {name=real, creturned=true}})
   end

   if Tensor == 'FloatTensor' or Tensor == 'DoubleTensor' then

      wrap("mean",
           cname("meanall"),
           {{name=Tensor},
            {name=accreal, creturned=true}},
           cname("mean"),
           {{name=Tensor, default=true, returned=true},
            {name=Tensor},
            {name="index"}})

      for _,name in ipairs({"var", "std"}) do
         wrap(name,
              cname(name .. "all"),
              {{name=Tensor},
               {name=accreal, creturned=true}},
              cname(name),
              {{name=Tensor, default=true, returned=true},
               {name=Tensor},
               {name="index"},
               {name="boolean", default=false}})
      end
      wrap("histc",
           cname("histc"),
           {{name=Tensor, default=true, returned=true},
            {name=Tensor},
            {name="long",default=100},
            {name="double",default=0},
            {name="double",default=0}})

      wrap("norm",
           cname("normall"),
           {{name=Tensor},
            {name=real, default=2},
            {name=accreal, creturned=true}},
           cname("norm"),
           {{name=Tensor, default=true, returned=true},
            {name=Tensor},
            {name=real},
            {name="index"}})

      wrap("renorm",
           cname("renorm"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}},
            {name=real},
            {name="index"},
            {name=real}})

      wrap("dist",
           cname("dist"),
           {{name=Tensor},
            {name=Tensor},
            {name=real, default=2},
            {name=accreal, creturned=true}})

      wrap("linspace",
           cname("linspace"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=real},
            {name=real},
            {name="long", default=100}})

      wrap("logspace",
           cname("logspace"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=real},
            {name=real},
            {name="long", default=100}})

      for _,name in ipairs({"log", "log1p", "exp",
                            "cos", "acos", "cosh",
                            "sin", "asin", "sinh",
                            "tan", "atan", "tanh",
                            "sqrt", "round", "ceil",
                            "floor", "trunc", }) do
         wrap(name,
              cname(name),
              {{name=Tensor, default=true, returned=true, method={default='nil'}},
               {name=Tensor, method={default=1}}},
              name,
              {{name=real},
               {name=real, creturned=true}})
      end

      wrap("abs",
           cname("abs"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}}},
           "fabs",
           {{name=real},
            {name=real, creturned=true}})

      wrap("frac",
           cname("frac"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}}},
           "TH_frac",
           {{name=real},
            {name=real, creturned=true}})

      wrap("rsqrt",
           cname("rsqrt"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}}},
           "TH_rsqrt",
           {{name=real},
            {name=real, creturned=true}})

      wrap("sigmoid",
           cname("sigmoid"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}}},
           "TH_sigmoid",
           {{name=real},
            {name=real, creturned=true}})

      wrap("neg",
           cname("neg"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}}})

      wrap("cinv",
           cname("cinv"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}}})

      wrap("lerp",
           cname("lerp"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}},
            {name=Tensor},
            {name=real}},
           "TH_lerp",
           {{name=real},
            {name=real},
            {name=real},
            {name=real, creturned=true}})

      wrap("atan2",
           cname("atan2"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}},
            {name=Tensor}},
           "atan2",
           {{name=real},
            {name=real},
            {name=real, creturned=true}})

      wrap("pow",
           cname("pow"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}},
            {name=real}},
           cname("tpow"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=real},
            {name=Tensor, method={default=1}}},
           "pow",
           {{name=real},
            {name=real},
            {name=real, creturned=true}})

      wrap("rand",
           cname("rand"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name='Generator', default=true},
            {name="LongArg"}})

      wrap("randn",
           cname("randn"),
           {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name='Generator', default=true},
            {name="LongArg"}})

      wrap("multinomial",
           cname("multinomial"),
           {{name="IndexTensor", default=true, returned=true, method={default='nil'}},
            {name='Generator', default=true},
            {name=Tensor},
            {name="int"},
            {name="boolean", default=false}})

      for _,f in ipairs({{name='uniform', a=0, b=1},
                         {name='normal', a=0, b=1},
                         {name='cauchy', a=0, b=1},
                         {name='logNormal', a=1, b=2}}) do

         wrap(f.name,
              string.format("THRandom_%s", f.name),
              {{name='Generator', default=true},
               {name="double", default=f.a},
               {name="double", default=f.b},
               {name="double", creturned=true}},
              cname(f.name),
              {{name=Tensor, returned=true},
               {name='Generator', default=true},
               {name=real, default=f.a},
               {name=real, default=f.b}})
      end

      for _,f in ipairs({{name='exponential'}}) do

         wrap(f.name,
              string.format("THRandom_%s", f.name),
              {{name='Generator', default=true},
               {name="double", default=f.a},
               {name="double", creturned=true}},
              cname(f.name),
              {{name=Tensor, returned=true},
               {name='Generator', default=true},
               {name=real, default=f.a}})
      end

      for _,name in ipairs({"gesv","gels"}) do
         interface:wrap(name,
                        cname(name),
                        {{name=Tensor, returned=true},
                         {name=Tensor, returned=true},
                         {name=Tensor},
                         {name=Tensor}},
                        cname(name),
                        {{name=Tensor, default=true, returned=true, invisible=true},
                         {name=Tensor, default=true, returned=true, invisible=true},
                         {name=Tensor},
                         {name=Tensor}}
                     )
      end
      interface:wrap("trtrs",
                     cname("trtrs"),
                     {{name=Tensor, returned=true},
                      {name=Tensor, returned=true},
                      {name=Tensor},
                      {name=Tensor},
                      {name='charoption', values={'U', 'L'}, default='U'},  -- uplo
                      {name='charoption', values={'N', 'T'}, default='N'},  -- trans
                      {name='charoption', values={'N', 'U'}, default='N'}}, -- diag
                     cname("trtrs"),
                     {{name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor},
                      {name=Tensor},
                      {name='charoption', values={'U', 'L'}, default='U'},  -- uplo
                      {name='charoption', values={'N', 'T'}, default='N'},  -- trans
                      {name='charoption', values={'N', 'U'}, default='N'}}  -- diag
                  )

      interface:wrap("symeig",
                     cname("syev"),
                     {{name=Tensor, returned=true},
                      {name=Tensor, returned=true},
                      {name=Tensor},
                      {name='charoption', values={'N', 'V'}, default='N'},
                      {name='charoption', values={'U', 'L'}, default='U'}},
                     cname("syev"),
                     {{name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor},
                      {name='charoption', values={'N', 'V'}, default='N'},
                      {name='charoption', values={'U', 'L'}, default='U'}}
                  )
      interface:wrap("eig",
                     cname("geev"),
                     {{name=Tensor, returned=true},
                      {name=Tensor, returned=true},
                      {name=Tensor},
                      {name='charoption', values={'N', 'V'}, default='N'}},
                     cname("geev"),
                     {{name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor},
                      {name='charoption', values={'N', 'V'}, default='N'}}
                  )

      interface:wrap("svd",
                     cname("gesvd"),
                     {{name=Tensor, returned=true},
                      {name=Tensor, returned=true},
                      {name=Tensor, returned=true},
                      {name=Tensor},
                      {name='charoption', values={'A', 'S'}, default='S'}},
                     cname("gesvd"),
                     {{name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor},
                      {name='charoption', values={'A', 'S'}, default='S'}}
                  )
      interface:wrap("inverse",
                     cname("getri"),
                     {{name=Tensor, returned=true},
                      {name=Tensor}},
                     cname("getri"),
                     {{name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor}}
                  )
      interface:wrap("potrf",
                     cname("potrf"),
                     {{name=Tensor, returned=true},
                      {name=Tensor},
                      {name='charoption', values={'U', 'L'}, default='U'}}, -- uplo
                     cname("potrf"),
                     {{name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor},
                      {name='charoption', values={'U', 'L'}, default='U'}}
                  )
      interface:wrap("potrs",
                     cname("potrs"),
                     {{name=Tensor, returned=true},
                      {name=Tensor},
                      {name=Tensor},
                      {name='charoption', values={'U', 'L'}, default='U'}}, -- uplo
                     cname("potrs"),
                     {{name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor},
                      {name=Tensor},
                      {name='charoption', values={'U', 'L'}, default='U'}}
                  )
      interface:wrap("potri",
                     cname("potri"),
                     {{name=Tensor, returned=true},
                      {name=Tensor},
                      {name='charoption', values={'U', 'L'}, default='U'}}, -- uplo
                     cname("potri"),
                     {{name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor},
                      {name='charoption', values={'U', 'L'}, default='U'}} -- uplo
                    )
      interface:wrap("pstrf",
                     cname("pstrf"),
                     {{name=Tensor, returned=true},
                      {name='IntTensor', returned=true},
                      {name=Tensor},
                      {name='charoption', values={'U', 'L'}, default='U'},  -- uplo
                      {name=real, default=-1}},
                     cname("pstrf"),
                     {{name=Tensor, default=true, returned=true, invisible=true},
                      {name='IntTensor', default=true, returned=true, invisible=true},
                      {name=Tensor},
                      {name='charoption', values={'U', 'L'}, default='U'},  -- uplo
                      {name=real, default=-1}}
                  )
      interface:wrap("qr",
                     cname("qr"),
                     {{name=Tensor, returned=true},
                      {name=Tensor, returned=true},
                      {name=Tensor}},
                     cname("qr"),
                     {{name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor}}
                  )
      interface:wrap("geqrf",
                     cname("geqrf"),
                     {{name=Tensor, returned=true},
                      {name=Tensor, returned=true},
                      {name=Tensor}},
                     cname("geqrf"),
                     {{name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor}}
                  )
      interface:wrap("orgqr",
                     cname("orgqr"),
                     {{name=Tensor, returned=true},
                      {name=Tensor},
                      {name=Tensor}},
                     cname("orgqr"),
                     {{name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor},
                      {name=Tensor}}
                  )
      interface:wrap("ormqr",
                     cname("ormqr"),
                     {{name=Tensor, returned=true},
                      {name=Tensor},
                      {name=Tensor},
                      {name=Tensor},
                      {name='charoption', values={'L', 'R'}, default='L'},
                      {name='charoption', values={'N', 'T'}, default='N'}},
                     cname("ormqr"),
                     {{name=Tensor, default=true, returned=true, invisible=true},
                      {name=Tensor},
                      {name=Tensor},
                      {name=Tensor},
                      {name='charoption', values={'L', 'R'}, default='L'},
                      {name='charoption', values={'N', 'T'}, default='N'}}
                  )
   end

   method:register(string.format("m_torch_%sMath__", Tensor))
   interface:print(method:tostring())
   method:clearhistory()
   interface:register(string.format("torch_%sMath__", Tensor))

   interface:print(string.gsub([[
static void torch_TensorMath_init(lua_State *L)
{
  luaT_pushmetatable(L, "torch.Tensor");

  /* register methods */
  luaT_setfuncs(L, m_torch_TensorMath__, 0);

  /* register functions into the "torch" field of the tensor metaclass */
  lua_pushstring(L, "torch");
  lua_newtable(L);
  luaT_setfuncs(L, torch_TensorMath__, 0);
  lua_rawset(L, -3);
  lua_pop(L, 1);
}
]], 'Tensor', Tensor))
end

interface:dispatchregister("torch_TensorMath__")

interface:print([[
void torch_TensorMath_init(lua_State *L)
{
  torch_ByteTensorMath_init(L);
  torch_CharTensorMath_init(L);
  torch_ShortTensorMath_init(L);
  torch_IntTensorMath_init(L);
  torch_LongTensorMath_init(L);
  torch_FloatTensorMath_init(L);
  torch_HalfTensorMath_init(L);
  torch_DoubleTensorMath_init(L);
  luaT_setfuncs(L, torch_TensorMath__, 0);
}
]])

if arg[1] then
   interface:tofile(arg[1])
else
   print(interface:tostring())
end
