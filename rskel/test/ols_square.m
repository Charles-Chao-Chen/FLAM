% Overdetermined least squares on the unit square, thin-plate splines.
%
% This is the direct analogue of OLS_LINE in 2D.

function ols_square(m,n,lambda,occ,p,rank_or_tol,store,doiter)

  % set default parameters
  if nargin < 1 || isempty(m), m = 16384; end  % number of row points
  if nargin < 2 || isempty(n), n = 64; end     % number of col points in one dim
  if nargin < 3 || isempty(lambda), lambda = 0.1; end  % regularization
  if nargin < 4 || isempty(occ), occ = 128; end
  if nargin < 5 || isempty(p), p = 64; end  % half number of proxy points
  if nargin < 6 || isempty(rank_or_tol), rank_or_tol = 1e-6; end
  if nargin < 7 || isempty(store), store = 'a'; end  % FMM storage mode
  if nargin < 8 || isempty(doiter), doiter = 1; end  % naive LSQR/CG?

  % initialize
  rx = rand(2,m);                                               % row points
  [x1,x2] = ndgrid((1:n)/n); cx = [x1(:) x2(:)]'; clear x1 x2;  % col points
  M = size(rx,2);
  N = size(cx,2);
  % proxy points -- two concentric rings (thin-plate splines are Green's
  % function for biharmonic equation; no Green's theorem)
  theta = (1:p)*2*pi/p;
  proxy = 1.5*[cos(theta); sin(theta)]; proxy = [proxy 2*proxy];
  % reference proxy points are for unit box [-1, 1]^2

  % compress matrix using RSKEL
  Afun = @(i,j)Afun_(i,j,rx,cx);
  pxyfun = @(rc,rx,cx,slf,nbr,l,ctr)pxyfun_(rc,rx,cx,slf,nbr,l,ctr,proxy);
  opts = struct('verb',1);
  tic; F = rskel(Afun,rx,cx,occ,rank_or_tol,pxyfun,opts); t = toc;
  w = whos('F'); mem = w.bytes/1e6;
  fprintf('rskel time/mem: %10.4e (s) / %6.2f (MB)\n',t,mem)

  % compress matrix using IFMM
  rank_or_tol = max(rank_or_tol*1e-2,1e-15);  % higher accuracy for reference
  opts = struct('store',store);
  tic; G = ifmm(Afun,rx,cx,occ,rank_or_tol,pxyfun,opts); t = toc;
  w = whos('G'); mem = w.bytes/1e6;
  fprintf('ifmm time/mem: %10.4e (s) / %6.2f (MB)\n',t,mem)

  % test accuracy using randomized power method
  X = rand(N,1);
  X = X/norm(X);

  % NORM(A - F)/NORM(A)
  tic; rskel_mv(F,X); t = toc;  % for timing
  err = snorm(N,@(x)(ifmm_mv(G,x,Afun,'n') - rskel_mv(F,x,'n')), ...
                @(x)(ifmm_mv(G,x,Afun,'c') - rskel_mv(F,x,'c')));
  err = err/snorm(N,@(x)ifmm_mv(G,x,Afun,'n'),@(x)ifmm_mv(G,x,Afun,'c'));
  fprintf('rskel_mv err/time: %10.4e / %10.4e (s)\n',err,t)
  tic; ifmm_mv(G,X,Afun); t = toc;
  fprintf('ifmm_mv time: %10.4e (s)\n',t)

  % build extended sparsification
  tau = eps^(-1/3);
  tic
  A = rskel_xsp(F);
  A = [tau*A(M+1:end,:); A(1:M,:); lambda*speye(N) sparse(N,size(A,2)-N)];
  t = toc;
  w = whos('A'); mem = w.bytes/1e6;
  fprintf('rskel_xsp:\n')
  fprintf('  build time/mem: %10.4e (s) / %6.2f (MB)\n',t,mem);

  % factor extended sparsification
  tic; R = qr(A,0); t = toc;
  w = whos('R'); mem = w.bytes/1e6;
  fprintf('  qr time/mem: %10.4e (s) / %6.2f (MB)\n',t,mem)
  ls = @(X)ls_(A,R,X,M,N,tau);  % least squares solve function

  % test pseudoinverse apply accuracy
  B = ifmm_mv(G,X,Afun);                 % random right-hand side in range
  tic; [Y,cres,niter] = ls(B); t = toc;  % least squares solve
  err1 = norm(X - Y)/norm(X);
  err2 = norm(B - ifmm_mv(G,Y,Afun))/norm(B);
  fprintf('ls:\n')
  fprintf('  soln/resid err/time: %10.4e / %10.4e / %10.4e (s)\n',err1,err2,t)
  fprintf('  constraint resid/iter/soln norm: %10.4e / %d / %10.4e\n', ...
          norm(cres),niter,norm(Y))

  iter = nan;
  if ~isoctave()
    C = [B; zeros(N,1)];
    mv = @(x,trans)mv_lsqr(G,x,trans,Afun,M,lambda);

    % run LSQR
    if doiter, [~,~,~,iter] = lsqr(mv,C,1e-6,128); end

    % run LSQR with initial guess from pseudoinverse
    tic; [Z,~,~,piter] = lsqr(mv,C,1e-6,32,[],[],Y); t = toc;
    fprintf('lsqr:\n')
  else
    warning('No LSQR in Octave.')

    C = ifmm_mv(G,B,Afun,'c');
    mv = @(x)mv_cg(G,x,Afun,lambda);

    % run CG (on normal equations)
    if doiter, [~,~,~,iter] = pcg(mv,C,1e-6,128); end

    % run CG with initial guess from pseudoinverse
    tic; [Z,~,~,piter] = pcg(mv,C,1e-6,32,[],[],Y); t = toc;
    fprintf('cg:\n')
  end
  err1 = norm(X - Z)/norm(X);
  err2 = norm(B - ifmm_mv(G,Z,Afun))/norm(B);
  fprintf('  soln/resid err/time: %10.4e / %10.4e / %10.4e (s)\n',err1,err2,t)
  fprintf('  init/uninit iter: %d / %d\n',piter,iter)
end

% kernel function
function K = Kfun(x,y)
  dx = x(1,:)' - y(1,:);
  dy = x(2,:)' - y(2,:);
  dr = sqrt(dx.^2 + dy.^2);
  K = dr.^2.*log(dr);
end

% matrix entries
function A = Afun_(i,j,rx,cx)
  A = Kfun(rx(:,i),cx(:,j));
end

% proxy function
function [Kpxy,nbr] = pxyfun_(rc,rx,cx,slf,nbr,l,ctr,proxy)
  pxy = proxy*l + ctr';  % scale and translate reference points
  if rc == 'r'
    Kpxy = Kfun(rx(:,slf),pxy);
    dx = cx(1,nbr) - ctr(1);
    dy = cx(2,nbr) - ctr(2);
  else
    Kpxy = Kfun(pxy,cx(:,slf));
    dx = rx(1,nbr) - ctr(1);
    dy = rx(2,nbr) - ctr(2);
  end
  % proxy points form circle of scaled radius 1.5 around current box
  % keep among neighbors only those within circle
  dist = sqrt(dx.^2 + dy.^2);
  nbr = nbr(dist/l < 1.5);
end

% weighted least squares solve
function x = lsfun(A,R,b)
  x = R\(R'\(A'*b));              % normal equation solve with one step of
  x = x + R\(R'\(A'*(b - A*x)));  % iterative refinement for accuracy
end

% equality-constrained least squares solve
function [Y,cres,niter] = ls_(A,R,X,M,N,tau)
  p = size(X,2);
  X = [X; zeros(N,p)];     % for regularization
  nc = size(A,1) - M - N;  % number of constraints
  % deferred correction for iterated weighted least squares
  [Y,cres,niter] = lsedc(@(b)lsfun(A,R,b),A(nc+1:end,:),X,A(1:nc,:)/tau, ...
                         zeros(nc,p),tau);
  Y = Y(1:N,:);
end

% matrix multiply for LSQR
function y = mv_lsqr(F,x,trans,Afun,M,lambda)
  if strcmpi(trans,'notransp')
    y = [ifmm_mv(F,x,Afun,'n'); lambda*x];
  elseif strcmpi(trans,'transp')
    y = ifmm_mv(F,x(1:M),Afun,'c') + lambda*x(M+1:end);
  end
end

% matrix multiply for CG
function y = mv_cg(F,x,Afun,lambda)
  y = ifmm_mv(F,ifmm_mv(F,x,Afun,'n'),Afun,'c') + lambda^2*x;
end