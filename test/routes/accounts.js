var expect = require('expect.js')
, accounts = require(__filename.replace('test', 'lib'))

describe('accounts', function() {
	describe('configure', function() {
		it('adds expected routes', function() {
			var routes = []
			, app = {
				post: function(url) { routes.push('post ' + url) },
				get: function(url) { routes.push('get ' + url) }
			}
			accounts.configure(app, null, 'BTC')
			expect(routes).to.contain('get /private/accounts')
		})
	})

	describe('forUser', function() {
		it('returns accounts', function(done) {
			var conn = {
				query: function(q, c) {
					expect(q.text).to.match(/from account_view/i)
					expect(q.values).to.eql([25])
					c(null, { rows: [{ account_id: 301 }] })
				}
			}
			, req = {
				security: { userId: 25 }
			}
			, res = {
				send: function(r) {
					expect(r).to.be.an('array')
					expect(r[0].account_id).to.be(301)
					done()
				}
			}

			accounts.forUser(conn, req, res, done)
		})
	})
})
