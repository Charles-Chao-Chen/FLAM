% HIFDE_SV_NC  Dispatch for HIFDE_SV with F.SYMM = 'N' and TRANS = 'C'.
%
%    See also HIFDE2, HIFDE2X, HIFDE3, HIFDE3X, HIFDE_SV.

function Y = hifde_sv_nc(F,X)

  % initialize
  n = F.lvp(end);
  Y = X;

  % upward sweep
  for i = 1:n
    sk = F.factors(i).sk;
    rd = F.factors(i).rd;
    T = F.factors(i).T;
    if ~isempty(T), Y(rd,:) = Y(rd,:) - T'*Y(sk,:); end
    Y(rd,:) = F.factors(i).U'\Y(rd,:);
    Y(sk,:) = Y(sk,:) - F.factors(i).F'*Y(rd,:);
  end

  % downward sweep
  for i = n:-1:1
    sk = F.factors(i).sk;
    rd = F.factors(i).rd;
    T = F.factors(i).T;
    Y(rd,:) = Y(rd,:) - F.factors(i).E'*Y(sk,:);
    Y(rd(F.factors(i).p),:) = F.factors(i).L'\Y(rd,:);
    if ~isempty(T), Y(sk,:) = Y(sk,:) - F.factors(i).T*Y(rd,:); end
  end
end