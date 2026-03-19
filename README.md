# brace_lua
lua preprocessor/transpiler that adds some js looking syntactic sugar
---
replaces all instances of PI with constant
```c++
define PI 3.14159
```
---
creates table something like `local style = {SlickBack = 1, Afro = 2}` etc.
```c++
enum Style {
  SlickBack,
  Afro,
  Bald
}
```
---
replaces ugly local keyword. glet is global let
```js
let a = 12
glet b = 192
```
---
gives `a = a + 1` has no problem with tables
```c++
a += 1
a++
b[12] *= 42
```
---
uses braces and instantly assumes function to be local unless otherwise specified
```js
function sqrt(x) {
  return math.sqrt(x)
}

global function something() { return }
```
---
uses braces for cleaner control flow
```js
if (x == 2) {
  print("no more 'then' or 'end' thank you")
}
```
---
allows raw lua insertion if necessary
```lua
$[
  if x == 1 then
    print("i love this number")
  end
]$
```
