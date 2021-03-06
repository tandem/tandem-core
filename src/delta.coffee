# Copyright (c) 2012, Salesforce.com, Inc.  All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.  Redistributions in binary
# form must reproduce the above copyright notice, this list of conditions and
# the following disclaimer in the documentation and/or other materials provided
# with the distribution.  Neither the name of Salesforce.com nor the names of
# its contributors may be used to endorse or promote products derived from this
# software without specific prior written permission.

_        = require('lodash')
jsdiff   = require('diff')
Op       = require('./op')
InsertOp = require('./insert')
RetainOp = require('./retain')

class Delta
  @getIdentity: (length) ->
    return new Delta(length, length, [new RetainOp(0, length)])

  @getInitial: (contents) ->
    return new Delta(0, contents.length, [new InsertOp(contents)])

  @isDelta: (delta) ->
    if (delta? && typeof delta == "object" && typeof delta.startLength == "number" &&
        typeof delta.endLength == "number" && typeof delta.ops == "object")
      for op in delta.ops
        return false unless Op.isRetain(op) or Op.isInsert(op)
      return true
    return false

  @makeDelta: (obj) ->
    return new Delta(obj.startLength, obj.endLength, _.map(obj.ops, (op) ->
      if Op.isInsert(op)
        return new InsertOp(op.value, op.attributes)
      else if Op.isRetain(op)
        return new RetainOp(op.start, op.end, op.attributes)
      else
        return null
    ))

  @makeDeleteDelta: (startLength, index, length) ->
    ops = []
    ops.push(new RetainOp(0, index)) if 0 < index
    ops.push(new RetainOp(index + length, startLength)) if index + length < startLength
    return new Delta(startLength, ops)

  @makeInsertDelta: (startLength, index, value, attributes) ->
    ops = [new InsertOp(value, attributes)]
    ops.unshift(new RetainOp(0, index)) if 0 < index
    ops.push(new RetainOp(index, startLength)) if index < startLength
    return new Delta(startLength, ops)

  @makeRetainDelta: (startLength, index, length, attributes) ->
    ops = [new RetainOp(index, index + length, attributes)]
    ops.unshift(new RetainOp(0, index)) if 0 < index
    ops.push(new RetainOp(index + length, startLength)) if index + length < startLength
    return new Delta(startLength, ops)

  constructor: (@startLength, @endLength, @ops) ->
    unless @ops?
      @ops = @endLength
      @endLength = null
    @ops = _.map(@ops, (op) ->
      if Op.isRetain(op)
        return op
      else if Op.isInsert(op)
        return op
      else
        throw new Error("Creating delta with invalid op. Expecting an insert or retain.")
    )
    this.compact()
    length = _.reduce(@ops, (count, op) ->
      return count + op.getLength()
    , 0)
    if @endLength? and length != @endLength
      throw new Error("Expecting end length of #{length}")
    else
      @endLength = length

  # insertFn(index, text), deleteFn(index, length), applyAttrFn(index, length, attribute, value)
  apply: (insertFn = (->), deleteFn = (->), applyAttrFn = (->), context = null) ->
    return if this.isIdentity()
    index = 0       # Stores where the last retain end was, so if we see another one, we know to delete
    offset = 0      # Tracks how many characters inserted to correctly offset new text
    retains = []
    _.each(@ops, (op) =>
      if Op.isInsert(op)
        insertFn.call(context, index + offset, op.value, op.attributes)
        offset += op.getLength()
      else if Op.isRetain(op)
        if op.start > index
          deleteFn.call(context, index + offset, op.start - index)
          offset -= (op.start - index)
        retains.push(new RetainOp(op.start + offset, op.end + offset, op.attributes))
        index = op.end
    )
    # If end of text was deleted
    if @endLength < @startLength + offset
      deleteFn.call(context, @endLength, @startLength + offset - @endLength)
    _.each(retains, (op) =>
      # In case we have instruction that is replace attr1 with attr2 by att1 -> null -> attr2
      # we need to apply null first since otherwise attr1 -> attr2 -> null is not what we want
      _.each(op.attributes, (value, format) =>
        applyAttrFn.call(context, op.start, op.end - op.start, format, value) if value == null
      )
      _.each(op.attributes, (value, format) =>
        applyAttrFn.call(context, op.start, op.end - op.start, format, value) if value?
      )
    )

  applyToText: (text) ->
    delta = this
    if text.length != delta.startLength
      throw new Error("Start length of delta: #{delta.startLength} is not equal to the text: #{text.length}")
    appliedText = []
    for op in delta.ops
      if Op.isInsert(op)
        appliedText.push(op.value)
      else
        appliedText.push(text.substring(op.start, op.end))
    result = appliedText.join("")
    if delta.endLength != result.length
      throw new Error("End length of delta: #{delta.endLength} is not equal to result text: #{result.length}")
    return result

  canCompose: (delta) ->
    return Delta.isDelta(delta) and @endLength == delta.startLength

  compact: ->
    compacted = []
    _.each(@ops, (op) ->
      return if op.getLength() == 0
      if compacted.length == 0
        compacted.push(op)
      else
        last = _.last(compacted)
        if Op.isInsert(last) && Op.isInsert(op) && last.attributesMatch(op)
          compacted[compacted.length - 1] = new InsertOp(last.value + op.value, op.attributes)
        else if Op.isRetain(last) && Op.isRetain(op) && last.end == op.start && last.attributesMatch(op)
          compacted[compacted.length - 1] = new RetainOp(last.start, op.end, op.attributes)
        else
          compacted.push(op)
    )
    @ops = compacted

  # Inserts in deltaB are given priority. Retains in deltaB are indexes into A,
  # and we take whatever is there (insert or retain).
  compose: (deltaB) ->
    throw new Error('Cannot compose delta') unless this.canCompose(deltaB)
    deltaA = this
    composed = []
    for opInB in deltaB.ops
      if Op.isInsert(opInB)
        composed.push(opInB)
      else if Op.isRetain(opInB)
        opsInRange = deltaA.getOpsAt(opInB.start, opInB.getLength())
        opsInRange = _.map(opsInRange, (opInA) ->
          if Op.isInsert(opInA)
            return new InsertOp(opInA.value, opInA.composeAttributes(opInB.attributes))
          else
            return new RetainOp(opInA.start, opInA.end, opInA.composeAttributes(opInB.attributes))
        )
        composed = composed.concat(opsInRange)
      else
        throw new Error('Invalid op in deltaB when composing')
    return new Delta(deltaA.startLength, deltaB.endLength, composed)

  # For each element in deltaC, compare it to the current element in deltaA in
  # order to construct deltaB. Given A and C, there is more than one valid B.
  # Its impossible to guarantee that decompose yields the actual B that was
  # used in the original composition. However, the function is deterministic in
  # which of the possible B's it chooses. How it works:
  # 1. Inserts in deltaC are matched against the current elem in deltaA. If
  #    there is a match, we create a corresponding retain in deltaB. Otherwise,
  #    we create an insertion in deltaB.
  # 2. We disallow retains in either of deltaA or deltaC.
  decompose: (deltaA) ->
    deltaC = this
    throw new Error("Decompose called when deltaA is not a Delta, type: " + typeof deltaA) unless Delta.isDelta(deltaA)
    throw new Error("startLength #{deltaA.startLength} / startLength #{@startLength} mismatch") unless deltaA.startLength == @startLength
    throw new Error("DeltaA has retain in decompose") unless _.all(deltaA.ops, ((op) -> return Op.isInsert(op)))
    throw new Error("DeltaC has retain in decompose") unless _.all(deltaC.ops, ((op) -> return Op.isInsert(op)))

    decomposeAttributes = (attrA, attrC) ->
      decomposedAttributes = {}
      for key, value of attrC
        if attrA[key] == undefined or attrA[key] != value
          if attrA[key] != null and typeof attrA[key] == 'object' and value != null and typeof value == 'object'
            decomposedAttributes[key] = decomposeAttributes(attrA[key], value)
          else
            decomposedAttributes[key] = value
      for key, value of attrA
        if attrC[key] == undefined
          decomposedAttributes[key] = null
      return decomposedAttributes

    insertDelta = deltaA.diff(deltaC)
    ops = []
    offset = 0
    _.each(insertDelta.ops, (op) ->
      opsInC = deltaC.getOpsAt(offset, op.getLength())
      offsetC = 0
      _.each(opsInC, (opInC) ->
        if Op.isInsert(op)
          d = new InsertOp(op.value.substring(offsetC, offsetC + opInC.getLength()), opInC.attributes)
          ops.push(d)
        else if Op.isRetain(op)
          opsInA = deltaA.getOpsAt(op.start + offsetC, opInC.getLength())
          offsetA = 0
          _.each(opsInA, (opInA) ->
            attributes = decomposeAttributes(opInA.attributes, opInC.attributes)
            start = op.start + offsetA + offsetC
            e = new RetainOp(start, start + opInA.getLength(), attributes)
            ops.push(e)
            offsetA += opInA.getLength()
          )
        else
          throw new Error("Invalid delta in deltaB when composing")
        offsetC += opInC.getLength()
      )
      offset += op.getLength()
    )

    deltaB = new Delta(insertDelta.startLength, insertDelta.endLength, ops)
    return deltaB

  diff: (other) ->
    [textA, textC] = _.map([this, other], (delta) ->
      return _.map(delta.ops, (op) ->
        return if op.value? then op.value else ""
      ).join('')
    )
    unless textA == '' and textC == ''
      diff = jsdiff.diffChars(textA, textC)
      throw new Error("diffToDelta called with diff with length <= 0") if diff.length <= 0
      originalLength = 0
      finalLength = 0
      ops = []
      # For each difference apply them separately so we do not disrupt the cursor
      _.each(diff, (part) ->
        if part.added
          ops.push(new InsertOp(part.value))
          finalLength += part.value.length
        else if part.removed
          # No op since deletes are implied
          originalLength += part.value.length
        else
          ops.push(new RetainOp(originalLength, originalLength + part.value.length))
          originalLength += part.value.length
          finalLength += part.value.length
      )
      insertDelta = new Delta(originalLength, finalLength, ops)
    else
      insertDelta = new Delta(0, 0, [])
    return insertDelta

  _insertInsertCase = (elemA, elemB, indexes, aIsRemote) ->
    results = _.extend({}, indexes)
    length = Math.min(elemA.getLength(), elemB.getLength())
    if aIsRemote
      results.transformOp = new RetainOp(results.indexA, results.indexA + length)
      results.indexA += length
      if length == elemA.getLength()
        results.elemIndexA++
      else if length < elemA.getLength()
        results.elemA = _.last(elemA.split(length))
      else
        throw new Error("Invalid elem length in transform")
    else
      results.transformOp = _.first(elemB.split(length))
      results.indexB += length
      if length == elemB.getLength()
        results.elemIndexB++
      else
        results.elemB = _.last(elemB.split(length))
    return results

  _retainRetainCase = (elemA, elemB, indexes) ->
    {indexA, indexB, elemIndexA, elemIndexB} = indexes
    results = _.extend({}, indexes)
    if elemA.end < elemB.start
      # The retains don't match, so throw away the lower and advance.
      results.indexA += elemA.getLength()
      results.elemIndexA++
    else if elemB.end < elemA.start
      # The retains don't match, so throw away the lower and advance.
      results.indexB += elemB.getLength()
      results.elemIndexB++
    else
      # A subrange or the entire range matches
      if elemA.start < elemB.start
        results.indexA += (elemB.start - elemA.start)
        elemA = results.elemA = new RetainOp(elemB.start, elemA.end,
          elemA.attributes)
      else if elemB.start < elemA.start
        results.indexB += (elemA.start - elemB.start)
        elemB = results.elemB = new RetainOp(elemA.start, elemB.end,
          elemB.attributes)
      errMsg = "RetainOps must have same start length in transform"
      throw new Error(errMsg) if elemA.start != elemB.start
      length = Math.min(elemA.end, elemB.end) - elemA.start
      addedAttributes = elemA.addAttributes(elemB.attributes)
      # Keep the retain
      results.transformOp = new RetainOp(results.indexA,
        results.indexA + length, addedAttributes)
      results.indexA += length
      results.indexB += length
      if (elemA.end == elemB.end)
        results.elemIndexA++
        results.elemIndexB++
      else if (elemA.end < elemB.end)
        results.elemIndexA++
        results.elemB = _.last(elemB.split(length))
      else
        results.elemIndexB++
        results.elemA = _.last(elemA.split(length))

    if results.elemIndexA != indexes.elemIndexA
      results.elemA = null
    if results.elemIndexB != indexes.elemIndexB
      results.elemB = null

    return results

  # We compute the transform according to the following rules:
  # 1. Insertions in deltaA become retained characters in the transform
  # 2. Insertions in deltaB become inserted characters in the transform
  # 3. Characters retained in deltaA and deltaB become retained characters in
  #    the transform set
  transform: (deltaA, aIsRemote = false) ->
    if not Delta.isDelta(deltaA)
      errMsg = "Transform called when deltaA is not a Delta, type: "
      throw new Error(errMsg + typeof deltaA)

    deltaA = new Delta(deltaA.startLength, deltaA.endLength, deltaA.ops)
    deltaB = new Delta(@startLength, @endLength, @ops)
    transformOps = []
    indexA = indexB = 0 # Tracks character offset in the 'document'
    elemIndexA = elemIndexB = 0 # Tracks offset into the ops list

    _applyResults = (results) ->
      indexA = results.indexA if results.indexA?
      indexB = results.indexB if results.indexB?
      elemIndexA = results.elemIndexA if results.elemIndexA?
      elemIndexB = results.elemIndexB if results.elemIndexB?
      deltaA.ops[elemIndexA] = results.elemA if results.elemA?
      deltaB.ops[elemIndexB] = results.elemB if results.elemB?
      transformOps.push(results.transformOp) if results.transformOp?

    _buildIndexes = ->
      indexA: indexA
      indexB: indexB
      elemIndexA: elemIndexA
      elemIndexB: elemIndexB

    while elemIndexA < deltaA.ops.length and elemIndexB < deltaB.ops.length
      elemA = deltaA.ops[elemIndexA]
      elemB = deltaB.ops[elemIndexB]

      if Op.isInsert(elemA) and Op.isInsert(elemB)
        results = _insertInsertCase(elemA, elemB, _buildIndexes(), aIsRemote)
        _applyResults(results)

      else if Op.isRetain(elemA) and Op.isRetain(elemB)
        results = _retainRetainCase(elemA, elemB, _buildIndexes())
        _applyResults(results)

      else if Op.isInsert(elemA) and Op.isRetain(elemB)
        transformOps.push(new RetainOp(indexA, indexA + elemA.getLength()))
        indexA += elemA.getLength()
        elemIndexA++

      else if Op.isRetain(elemA) and Op.isInsert(elemB)
        transformOps.push(elemB)
        indexB += elemB.getLength()
        elemIndexB++

    # Remaining loops account for different length deltas, only inserts will be
    # accepted
    while elemIndexA < deltaA.ops.length
      elemA = deltaA.ops[elemIndexA]
      if Op.isInsert(elemA) # retain elemA
        transformOps.push(new RetainOp(indexA, indexA + elemA.getLength()))
      indexA += elemA.getLength()
      elemIndexA++

    while elemIndexB < deltaB.ops.length
      elemB = deltaB.ops[elemIndexB]
      transformOps.push(elemB) if Op.isInsert(elemB) # insert elemB
      indexB += elemB.getLength()
      elemIndexB++

    transformStartLength = deltaA.endLength
    transformEndLength = _.reduce(transformOps, (transformEndLength, op) ->
      return transformEndLength + op.getLength()
    , 0)
    return new Delta(transformStartLength, transformEndLength, transformOps)

  getOpsAt: (index, length) ->
    changes = []
    if @savedOpOffset? and @savedOpOffset < index
      offset = @savedOpOffset
    else
      offset = @savedOpOffset = @savedOpIndex = 0
    for op in @ops.slice(@savedOpIndex)
      break if offset >= index + length
      opLength = op.getLength()
      if index < offset + opLength
        start = Math.max(index - offset, 0)
        getLength = Math.min(opLength - start, index + length - offset - start)
        changes.push(op.getAt(start, getLength))
      offset += opLength
      @savedOpIndex += 1
      @savedOpOffset += opLength
    return changes

  # Given A and B, returns B' s.t. ABB' yields A.
  invert: (deltaB) ->
    throw new Error("Invert called on invalid delta containing non-insert ops") unless this.isInsertsOnly()
    deltaA = this
    deltaC = deltaA.compose(deltaB)
    inverse = deltaA.decompose(deltaC)
    return inverse

  isEqual: (other) ->
    return false unless other
    return false if @startLength != other.startLength or @endLength != other.endLength
    return false if !_.isArray(other.ops) or @ops.length != other.ops.length
    return _.all(@ops, (op, i) ->
      op.isEqual(other.ops[i])
    )

  isIdentity: ->
    if @startLength == @endLength
      if @ops.length == 0
        return true
      index = 0
      for op in @ops
        if !Op.isRetain(op) then return false
        if op.start != index then return false
        if !(op.numAttributes() == 0 || (op.numAttributes() == 1 && _.has(op.attributes, 'authorId')))
          return false
        index = op.end
      if index != @endLength then return false
      return true
    return false

  isInsertsOnly: ->
    return _.every(@ops, (op) ->
      return Op.isInsert(op)
    )

  merge: (other) ->
    ops = _.map(other.ops, (op) =>
      if Op.isRetain(op)
        return new RetainOp(op.start + @startLength, op.end + @startLength, op.attributes)
      else
        return op
    )
    ops = @ops.concat(ops)
    return new Delta(@startLength + other.startLength, ops)

  split: (index) ->
    throw new Error("Split only implemented for inserts only") unless this.isInsertsOnly()
    throw new Error("Split at invalid index") unless 0 <= index and index <= @endLength
    leftOps = []
    rightOps = []
    _.reduce(@ops, (offset, op) ->
      if offset + op.getLength() <= index
        leftOps.push(op)
      else if offset >= index
        rightOps.push(op)
      else
        [left, right] = op.split(index - offset)
        leftOps.push(left)
        rightOps.push(right)
      return offset + op.getLength()
    , 0)
    return [new Delta(0, leftOps), new Delta(0, rightOps)]

  toString: ->
    return "{(#{@startLength}->#{@endLength}) [#{@ops.join(', ')}]}"


module.exports = Delta
