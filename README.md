# brace_lua
lua preprocessor/transpiler that adds some js looking syntactic sugar
---
replaces all instances of PI with constant
```
define PI 3.14159
```
---
creates table something like `local style = {SlickBack = 1, Afro = 2}` etc.
```
enum Style {
  SlickBack,
  Afro,
  Bald
}
```
---
replaces ugly local keyword. glet is global let
```
let a = 12
glet b = 192
```
---
gives `a = a + 1` has no problem with tables
```
a += 1
a++
b[12] *= 42
```
---
uses braces and instantly assumes function to be local unless otherwise specified
```
function sqrt(x) {
  return math.sqrt(x)
}

global function something() { return }
```
---
uses braces for cleaner control flow
```
if (x == 2) {
  print("no more 'then' or 'end' thank you)
}
```
---
allows raw lua insertion if necessary
```
$[
  if x == 1 then
    print("i love this number")
  end
]$
```
