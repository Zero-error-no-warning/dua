'use strict';
// Typed signatures for standard functions whose scalar results are useful to
// completion and signature help. User/catalog declarations still take priority.
module.exports = {
  count: {kind:'function',signatures:[{returnType:'int',parameters:[{name:'text',type:'string'}]}]},
  charAt: {kind:'function',signatures:[{returnType:'string',parameters:[{name:'text',type:'string'},{name:'index',type:'int'}]}]}
};
