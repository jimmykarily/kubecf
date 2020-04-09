#!/usr/bin/env ruby

# frozen_string_literal: true

# Variable interpolation via Bazel template expansion.
helm = '[[helm]]'

args = [helm, 'dep', 'up']

puts "CMD #{args}"

exit Process.wait2(Process.spawn(*args)).last.exitstatus
