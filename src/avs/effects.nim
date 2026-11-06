# Ported from Advanced Visualization Studio 2.81d, Copyright 2005 Nullsoft, Inc.
# BSD license: assets/licenses/AVS-Nullsoft-BSD.txt

## Every effect the engine knows, registered by AVS's index or APE name.

import render1, render2, misc, trans1, trans2, trans3, trans4, apes, apes2, apes3, text
export resetMultiDelay

proc registerAll*() =
  registerRender1()
  registerRender2()
  registerMisc()
  registerTrans1()
  registerTrans2()
  registerTrans3()
  registerTrans4()
  registerApes()
  registerApes2()
  registerApes3()
  registerText()
