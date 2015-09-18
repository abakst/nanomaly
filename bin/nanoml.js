var nodes = undefined;
var edges = undefined;
var steps = undefined;
var network = undefined;
var ctxmenu = undefined;

var sf_target = undefined;
var sb_target = undefined;
var jf_target = undefined;
var jb_target = undefined;

var single_width = 1;
var multi_width = 5;

function resetButtons() {
  sf_target = undefined;
  sb_target = undefined;
  jf_target = undefined;
  jb_target = undefined;

  document.getElementById('step-forward').disabled = true;
  document.getElementById('step-backward').disabled = true;
  document.getElementById('jump-forward').disabled = true;
  document.getElementById('jump-backward').disabled = true;
}

function isSingleStep(from, to) {
  return allEdges.get({filter: function(x) {
      return x.from === from && x.to === to;
    }}).length > 0;
}

function canStepForward(node) {
  // ctxmenu.style.visibility = 'hidden';
  console.log('stepForward');
  var out = allEdges.get({filter: function(x) {
    return x.from === node.id && x.label.indexOf('StepsTo') >= 0;
  }});
  var curEdge = network.body.data.edges.get({filter: function(x) {
    return x.from === node.id;
  }});
  if (out.length === 0 || curEdge.length === 0 || network.body.data.nodes.get(out[0].to) !== null) return;
  console.log(network.body.data.nodes.get(out[0]));
  out = out[0];
  curEdge = curEdge[0];
  console.log(out);
  sf_target = [out.to, curEdge];
  document.getElementById('step-forward').disabled = false;
  // insertNode(allNodes.get(next.from), edge);
}

function stepForward() {
  insertNode(allNodes.get(sf_target[0]), sf_target[1]);
  resetButtons();
}

function canStepBackward(node) {
  // ctxmenu.style.visibility = 'hidden';
  console.log('stepBackward');
  var inn = allEdges.get({filter: function(x) {
    return x.to === node.id && x.label.indexOf('StepsTo') >= 0;
  }});
  var curEdge = network.body.data.edges.get({filter: function(x) {
    return x.to === node.id;
  }});
  console.log(inn);
  if (inn.length === 0 || curEdge.length === 0 || network.body.data.nodes.get(inn[0].from) !== null) return;
  console.log(network.body.data.nodes.get(inn[0]));
  inn = inn[0];
  curEdge = curEdge[0];
  console.log(inn);
  sb_target = [inn.from, curEdge];
  document.getElementById('step-backward').disabled = false;
  // insertNode(allNodes.get(prev[0].from), edge);
}

function stepBackward() {
  insertNode(allNodes.get(sb_target[0]), sb_target[1]);
  resetButtons();
}

function canJumpForward(node) {
  // ctxmenu.style.visibility = 'hidden';
  console.log('jumpForward');
  var out = allEdges.get({filter: function(x) {
    return x.from === node.id &&
           x.label.indexOf('StepsTo') >= 0; // &&
           // x.label.indexOf('StepsTo CallStep') < 0;
  }});
  var curEdge = network.body.data.edges.get({filter: function(x) {
    return x.from === node.id;
  }});
  if (out.length === 0 || curEdge.length === 0) return;
  out = out[0];
  curEdge = curEdge[0];
  while (true) {
    var outEdges = allEdges.get({filter: function(x) {
      return x.from === out.to &&
             x.label.indexOf('StepsTo') >= 0;
    }});
    console.log(outEdges);
    if (outEdges.length === 0) break;
    if (outEdges[0].label === 'StepsTo CallStep') break;
    out = outEdges[0];
  }
  // if (isSingleStep(node.id, out.to)) return;
  if (network.body.data.nodes.get(out.to) !== null) return;
  console.log(out);
  jf_target = [out.to, curEdge];
  document.getElementById('jump-forward').disabled = false;
  // insertNode(allNodes.get(next.from), edge);
}

function jumpForward() {
  insertNode(allNodes.get(jf_target[0]), jf_target[1]);
  resetButtons();
}

function canJumpBackward(node) {
  // ctxmenu.style.visibility = 'hidden';
  console.log('jumpBackward');
  var inn = allEdges.get({filter: function(x) {
    return x.to === node.id &&
           x.label.indexOf('StepsTo') >= 0; // &&
           // x.label.indexOf('StepsTo CallStep') < 0;
  }});
  var curEdge = network.body.data.edges.get({filter: function(x) {
    return x.to === node.id;
  }});
  if (inn.length === 0 || curEdge.length === 0) return;
  inn = inn[0];
  curEdge = curEdge[0];
  while (true) {
    innEdges = allEdges.get({filter: function(x) {
      return x.to === inn.from &&
             x.label.indexOf('StepsTo') >= 0;
    }});
    console.log(innEdges);
    if (innEdges.length === 0) break;
    inn = innEdges[0];
    if (inn.label === 'StepsTo CallStep') break;
  }
  // if (isSingleStep(inn.from, node.id)) return;
  if (network.body.data.nodes.get(inn.from) !== null) return;
  console.log(inn);
  jb_target = [inn.from, curEdge];
  document.getElementById('jump-backward').disabled = false;
  // insertNode(allNodes.get(prev.from), edge);
}

function jumpBackward() {
  console.log(jb_target);
  insertNode(allNodes.get(jb_target[0]), jb_target[1]);
  resetButtons();
}

function insertNode(node, replacingEdge) {
  var pnodes = network.body.data.nodes;
  var pedges = network.body.data.edges;

  if (allEdges.get({filter: function(x) {
        return x.from === replacingEdge.from && x.to === node.id;
      }}).length > 0) {
    var width_in = single_width;
  } else {
    var width_in = multi_width;
  }
  if (allEdges.get({filter: function(x) {
        return x.from === node.id && x.to === replacingEdge.to;
      }}).length > 0) {
    var width_out = single_width;
  } else {
    var width_out = multi_width;
  }

  pnodes.add(node);
  pedges.add([{arrows: 'to', from: replacingEdge.from, to: node.id, width: width_in}
             ,{arrows: 'to', from: node.id, to: replacingEdge.to, width: width_out}]);
  pedges.remove(replacingEdge);

  network.setData({nodes: pnodes, edges: pedges});
  network.unselectAll();
  // network.stabilize();
  // network.redraw();
}

function draw() {
  ctxmenu = document.getElementById('menu');
  var container = document.getElementById('vis');
  var dot = document.getElementById('reduction-graph').text;
  var root = document.getElementById('root-node').text;
  var stuck = document.getElementById('stuck-node').text;
  data = vis.network.convertDot(dot);
  data.nodes.forEach(function(n) {
    n.label = n.label.replace(/\\n/g, "\n");
  });
  allNodes = new vis.DataSet(data.nodes);
  allEdges = new vis.DataSet(data.edges);
  var nodes = new vis.DataSet(data.nodes).get({filter: function(x) {
    return x.id === ('u' + root) || x.id === ('u' + stuck);
  }});
  if (allEdges.get({filter: function(x) {
        return x.from === ('u'+root) && x.to === ('u'+stuck);
      }}).length > 0) {
    var width = single_width;
  } else {
    var width = multi_width;
  }
  var edges = new vis.DataSet([{ arrows: 'to', from: ('u'+root), to: ('u'+stuck), width: width}]);
  // steps = new vis.DataSet(data.edges).get({filter: function (x) {
  //   return x.label.indexOf("StepsTo") === 0;
  // }});
  // console.log(steps);
  var options = {
    interaction: {
      selectConnectedEdges: false,
    },
    layout: {
      hierarchical: { direction: 'UD', sortMethod: 'directed' }
    },
    nodes: {
      font: { face: 'monospace' }
    },
    // edges: {
    //   label: "",
    // },
    // physics: { enabled: false},
  };
  network = new vis.Network(container, {nodes: nodes, edges: edges}, options);
    // network.on("hidePopup", function () {
    //     console.log('hidePopup Event');
    // });
    // network.on("select", function (params) {
    //     console.log('select Event:', params);
    // });
    // network.on("oncontext", function (params) {
    //     console.log('oncontext Event:', params);
    // });
    network.on("selectNode", function (params) {
        console.log('selectNode Event:', params);
        var node = network.body.data.nodes.get(network.getSelectedNodes()[0]);
        console.log(node);
        canStepForward(node);
        canStepBackward(node);
        canJumpForward(node);
        canJumpBackward(node);
        // ctxmenu.style.position = 'fixed';
        // ctxmenu.style.top  = params.event.center.x;
        // ctxmenu.style.left = params.event.center.y;
        // ctxmenu.style.visibility = 'visible';
        // ctxmenu.style.zIndex = 1;
    });
    network.on("selectEdge", function (params) {
        return false;
        console.log('selectEdge Event:', params);
        // canStepForward();
        // canStepBackward();
        // canJumpForward();
        // canJumpBackward();
    });
    network.on("deselectNode", function (params) {
        console.log('deselectNode Event:', params);
        resetButtons();
    });
    // network.on("deselectEdge", function (params) {
    //     console.log('deselectEdge Event:', params);
    //     resetButtons();
    // });
    // network.on("hoverNode", function (params) {
    //     console.log('hoverNode Event:', params);
    // });
    // network.on("hoverEdge", function (params) {
    //     console.log('hoverEdge Event:', params);
    // });
    // network.on("blurNode", function (params) {
    //     console.log('blurNode Event:', params);
    // });
    // network.on("blurEdge", function (params) {
    //     console.log('blurEdge Event:', params);
    // });
}
