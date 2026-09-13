require "./spec_helper"

module Gitorules
  describe "apply confirmation prompt" do
    it "includes blast radius with scope" do
      CLI.confirm_prompt(3, 2, "main").should eq "Apply 3 changes to 2 repos in scope main? [y/N] "
    end

    it "uses singular forms for single change and repo" do
      CLI.confirm_prompt(1, 1, "main").should eq "Apply 1 change to 1 repo in scope main? [y/N] "
    end

    it "omits scope when unavailable" do
      CLI.confirm_prompt(3, 2, nil).should eq "Apply 3 changes to 2 repos? [y/N] "
    end

    it "falls back to the generic prompt without counts" do
      CLI.confirm_prompt(nil, nil, nil).should eq "Apply these changes? [y/N] "
      CLI.confirm_prompt(nil, 2, "main").should eq "Apply these changes? [y/N] "
      CLI.confirm_prompt(3, nil, "main").should eq "Apply these changes? [y/N] "
    end

    it "detects planned deletions for the prune warning" do
      CLI.deletion_planned?("  + Create ruleset 'x'\n").should be_false
      CLI.deletion_planned?("  - Delete label 'old' (prune)\n").should be_true
      CLI.deletion_planned?("  - Orphan ruleset 'old'\n").should be_true
    end

    it "counts changed lines" do
      CLI.count_changes("  + Create ruleset 'a'\n  ~ Update ruleset 'b'\n  no changes\n").should eq 2
      CLI.count_changes("no changes\n").should eq 0
    end
  end
end
