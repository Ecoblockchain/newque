module.exports = function (id) {
  describe('Push ' + id, function () {
    var p, env
    before(function () {
      return Proc.setupEnvironment(id)
      .then(function (environment) {
        env = environment
        p = Proc.spawnExecutable()
        return Promise.delay(C.spawnDelay)
      })
    })

    describe('Single', function () {
      it('No header', function () {
        var buf = 'abcdef'
        return Fn.call('POST', 8000, '/v1/example', buf)
        .then(Fn.shouldFail(400))
      })

      it('No data', function () {
        var buf = ''
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'single']])
        .then(Fn.shouldHaveWritten(1))
      })

      it('With header', function () {
        var buf = 'abcdef'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'single']])
        .then(Fn.shouldHaveWritten(1))
      })

      it('With separator', function () {
        var buf = 'abc\ndef'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'single']])
        .then(Fn.shouldHaveWritten(1))
      })

      it('With bad header', function () {
        var buf = 'abcdef'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'invalid header']])
        .then(Fn.shouldFail(400))
      })
    })

    describe('Multiple', function () {
      it('Without separator', function () {
        var buf = 'abcdef'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'multiple']])
        .then(Fn.shouldHaveWritten(1))
      })

      it('With separator', function () {
        var buf = 'M abc\nM def\nM ghi\nM jkl'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'multiple']])
        .then(Fn.shouldHaveWritten(4))
      })

      it('With separator, secondary channel', function () {
        var buf = 'M abc--M def--M ghi--M jkl'
        return Fn.call('POST', 8000, '/v1/secondary', buf, [[C.modeHeader, 'multiple']])
        .then(Fn.shouldHaveWritten(4))
      })

      it('No data', function () {
        var buf = ''
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'multiple']])
        .then(Fn.shouldHaveWritten(1))
      })

      it('Empty messages', function () {
        var buf = '\n\na\n'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'multiple']])
        .then(Fn.shouldHaveWritten(4))
      })
    })

    describe('Atomic', function () {
      it('Without separator', function () {
        var buf = 'abcdefghijkl'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'atomic']])
        .then(Fn.shouldHaveWritten(1))
      })

      it('With separator', function () {
        var buf = 'A abc\nA def\nA ghi\nA jkl'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'atomic']])
        .then(Fn.shouldHaveWritten(1))
      })

      it('Empty messages', function () {
        var buf = '\n\nz\n'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'atomic']])
        .then(Fn.shouldHaveWritten(1))
      })
    })

    describe('Custom IDs', function () {
      // Set up an initial ID to track...
      var lastID = 'initial'
      before(function () {
        var buf = 'bzzz'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'single'], [C.idHeader, lastID]])
        .then(Fn.shouldHaveWritten(1))
      })

      it('Without separator, single mode', function () {
        var buf = 'A abc\nA def\nA ghi\nA jkl'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'single'], [C.idHeader, 'id1']])
        .then(Fn.shouldHaveWritten(1))
        // Check if only one was added after the previous lastID, then update the lastID
        .then(() => Fn.call('GET', 8000, '/v1/example', null, [[C.modeHeader, 'after_id ' + lastID]]))
        .then(Fn.shouldHaveRead([buf], '\n'))
        .then(result => lastID = result.res.headers[C.lastIdHeader])
      })

      it('With separator, single mode', function () {
        var buf = 'B abc\nB def\nB ghi\nB jkl'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'single'], [C.idHeader, 'id1,id2']])
        .then(Fn.shouldHaveWritten(1))
        // Check if only one was added after the previous lastID, then update the lastID
        .then(() => Fn.call('GET', 8000, '/v1/example', null, [[C.modeHeader, 'after_id ' + lastID]]))
        .then(Fn.shouldHaveRead([buf], '\n'))
        .then(result => lastID = result.res.headers[C.lastIdHeader])
      })

      it('Without separator', function () {
        var buf = 'abcdef'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'single'], [C.idHeader, 'id10,id11,id12,id13']])
        .then(Fn.shouldHaveWritten(1))
        // Check if only one was added after the previous lastID, then update the lastID
        .then(() => Fn.call('GET', 8000, '/v1/example', null, [[C.modeHeader, 'after_id ' + lastID]]))
        .then(Fn.shouldHaveRead([buf], '\n'))
        .then(result => lastID = result.res.headers[C.lastIdHeader])
      })

      it('With separator', function () {
        var buf = 'C abc\nC def\nC ghi\nC jkl'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'multiple'], [C.idHeader, 'id10,id11,id12,id13']])
        .then(Fn.shouldHaveWritten(4))
        // Check that 4 were added after the previous lastID, then update the lastID
        .then(() => Fn.call('GET', 8000, '/v1/example', null, [[C.modeHeader, 'after_id ' + lastID]]))
        .then(Fn.shouldHaveRead(buf.split('\n'), '\n'))
        .then(result => lastID = result.res.headers[C.lastIdHeader])
      })

      it('With separator, non-matching lengths 1', function () {
        var buf = 'D abc\nD def\nD ghi\nD jkl'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'multiple'], [C.idHeader, 'id20,id21,id22']])
        .then(Fn.shouldFail(400))
      })

      it('With separator, non-matching lengths 2', function () {
        var buf = 'E abc\nE def\nE ghi'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'multiple'], [C.idHeader, 'id30,id31,id32,id33']])
        .then(Fn.shouldFail(400))
      })

      it('With separator, empty IDs 1', function () {
        var buf = 'F abc\nF def\nF ghi'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'multiple'], [C.idHeader, 'id40,id41,id42,']])
        .then(Fn.shouldFail(400))
      })

      it('With separator, empty IDs 2', function () {
        var buf = 'G abc\nG def\nG ghi'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'multiple'], [C.idHeader, 'id50,id51,,id52,id53']])
        .then(Fn.shouldFail(400))
      })

      it('With separator, atomic', function () {
        var buf = 'H abc\nH def\nH ghi'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'atomic'], [C.idHeader, 'id60,id61,id62,']])
        .then(Fn.shouldHaveWritten(1))
        // Check that 3 were added after the previous lastID, then update the lastID
        .then(() => Fn.call('GET', 8000, '/v1/example', null, [[C.modeHeader, 'after_id ' + lastID]]))
        .then(Fn.shouldHaveRead(buf.split('\n'), '\n'))
        .then(result => lastID = result.res.headers[C.lastIdHeader])
      })

      it('With separator, skip existing', function () {
        var buf = 'I abc\nI def\nI ghi'
        return Fn.call('POST', 8000, '/v1/example', buf, [[C.modeHeader, 'multiple'], [C.idHeader, 'id70,id70,id1']])
        .then(Fn.shouldHaveWritten(1))
        // Check that 3 were added after the previous lastID, then update the lastID
        .then(() => Fn.call('GET', 8000, '/v1/example', null, [[C.modeHeader, 'after_id ' + lastID]]))
        .then(Fn.shouldHaveRead(['I abc'], '\n'))
        .then(result => Fn.assert(result.res.headers[C.lastIdHeader] === 'id70'))
      })
    })

    describe('Routing', function () {
      it('Invalid path, empty channel', function () {
        var buf = ''
        return Fn.call('POST', 8000, '/v1/', buf, [[C.modeHeader, 'single']])
        .then(Fn.shouldFail(400))
      })

      it('Invalid path, invalid channel', function () {
        var buf = ''
        return Fn.call('POST', 8000, '/v1/nothing', buf, [[C.modeHeader, 'single']])
        .then(Fn.shouldFail(400))
      })

      it('Invalid method', function () {
        var buf = ''
        return Fn.call('XYZ', 8000, '/v1/example', buf, [[C.modeHeader, 'single']])
        .then(Fn.shouldFail(405))
      })
    })

    describe('Read only', function () {
      it('Should error when trying to write', function () {
        var buf = 'qwerty'
        return Fn.call('POST', 8000, '/v1/readonly', buf, [[C.modeHeader, 'single']])
        .then(Fn.shouldFail(400))
      })
    })

    describe('Write only', function () {
      it('Should push', function () {
        var buf = 'qwerty'
        return Fn.call('POST', 8000, '/v1/writeonly', buf, [[C.modeHeader, 'single']])
        .then(Fn.shouldHaveWritten(1))
      })
    })

    after(function () {
      return Proc.stopExecutable(p)
    })
  })
}
