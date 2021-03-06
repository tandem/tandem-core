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

assert = require('chai').assert

Tandem = require('../index')
Delta      = Tandem.Delta
InsertOp   = Tandem.InsertOp
RetainOp   = Tandem.RetainOp

describe('isIdentity', ->
  it('should accept the identity with no attributes', ->
    delta = new Delta(10, 10, [new RetainOp(0, 10)])
    console.assert(delta.isIdentity() == true, "Expected delta #{delta.toString()}
    to be the identity, but delta.isIdentity() says its not")
  )

  it('should accept the identity with an author attribute', ->
    delta = new Delta(10, 10, [new RetainOp(0, 10, {authorId: 'Gandalf'})])
    console.assert(delta.isIdentity() == true, "Expected delta #{delta.toString()}
    to be the identity, but delta.isIdentity() says its not")
  )

  it('should accept the noncompacted identity', ->
    delta = new Delta(10, 10, [new RetainOp(0, 5), new RetainOp(5, 10)])
    console.assert(delta.isIdentity() == true, "Expected delta #{delta.toString()}
    to be the identity, but delta.isIdentity() says its not")
  )

  it('should accept the noncompacted identity with complete author attributes', ->
    delta = new Delta(10, 10, [new RetainOp(0, 5, {authorId: 'Gandalf'}), new
    RetainOp(5, 10, {authorId: 'Frodo'})])
    console.assert(delta.isIdentity() == true, "Expected delta #{delta.toString()}
    to be the identity, but delta.isIdentity() says its not")
  )

  it('should accept the noncompacted identity with partial author attribution', ->
    delta = new Delta(10, 10, [new RetainOp(0, 5), new RetainOp(5, 10, {authorId: 'Frodo'})])
    console.assert(delta.isIdentity() == true,
      "Expected delta #{delta.toString()} to be the identity, but delta.isIdentity() says its not")
  )

  it('should accept the noncompacted identity with partial author attribution', ->
    delta = new Delta(10, 10, [new RetainOp(0, 5, {authorId: 'Frodo'}),
                               new RetainOp(5, 10)])
    console.assert(delta.isIdentity() == true, "Expected delta #{delta.toString()}
    to be the identity, but delta.isIdentity() says its not")
  )

  it('should reject the complete retain of a document if it contains non-author attr', ->
    delta = new Delta(10, 10, [new RetainOp(0, 10, {bold: true})])
    console.assert(delta.isIdentity() == false, "Expected delta #{delta.toString()}
    not to be the identity, but delta.isIdentity() says it is")
  )

  it('should reject the complete retain of a document if it contains non-author attr', ->
    delta = new Delta(10, 10, [new RetainOp(0, 5, {bold: true}),
                               new RetainOp(5, 10, {authorId: 'Frodo'})])
    console.assert(delta.isIdentity() == false, "Expected delta #{delta.toString()}
    to not be the identity, but delta.isIdentity() says it is")
  )

  it('should reject the complete retain of a document if it contains non-author attr', ->
    delta = new Delta(10, 10, [new RetainOp(0, 5, {bold: true}),
                               new RetainOp(5, 10, {bold: null})])
    console.assert(delta.isIdentity() == false, "Expected delta #{delta.toString()}
    to not be the identity, but delta.isIdentity() says it is")
  )

  it('should reject the complete retain of a document if it contains non-author attr', ->
    delta = new Delta(10, 10, [new RetainOp(0, 5), new RetainOp(5, 10, {bold: true})])
    console.assert(delta.isIdentity() == false, "Expected delta #{delta.toString()}
    not to be the identity, but delta.isIdentity() says it is")
  )

  it('should reject the complete retain of a document if it contains non-author attr', ->
    delta = new Delta(10, 10, [new RetainOp(0, 10, {authorId: 'Gandalf', bold: true})])
    console.assert(delta.isIdentity() == false, "Expected delta #{delta.toString()}
    not to be the identity, but delta.isIdentity() says it is")
  )

  it('should reject any delta containing an InsertOp', ->
    delta = new Delta(10, 10, [new RetainOp(0, 4), new InsertOp("a"),
                               new RetainOp(5, 10, {authorId: 'Frodo'})])
    console.assert(delta.isIdentity() == false, "Expected delta #{delta.toString()}
    to not be the identity, but delta.isIdentity() says it is")
  )
)
